#!/usr/bin/env python3
"""Accumulating publisher for the static registry.

Copies the wheels of a freshly built registry (nix build .#pythonRegistry)
into the S3-compatible volume behind the index app and regenerates the index
HTML over everything published so far. Published wheel filenames are
immutable: a changed build of the same upstream version needs a rels.json
bump, and nothing is ever deleted, so old lockfiles keep resolving.

Volume layout (= the web root served by the app):
  index.html, simple/...     as in the nix output
  manifests/<wheel>.json     {project, sha256, metadata_sha256, requires_python,
                              + provenance: attr, drv_path, wasinix_rev}
The manifests carry what HTML regeneration needs, so republishing never
downloads a wheel. Provenance lets `nix build
github:wasix-org/wasinix/<wasinix_rev>#<attr>` rebuild a given wheel.

Usage: publish.py --registry <path> --remote <rclone-remote:bucket>
                  [--rev <wasinix git rev>] [--dry-run]
Credentials come from rclone env vars (RCLONE_CONFIG_<NAME>_*).
"""

import argparse
import hashlib
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "make_index", Path(__file__).with_name("make-index.py")
)
make_index = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(make_index)


def rclone(*args):
    cmd = ["rclone", "--quiet", *map(str, args)]
    print(f"  $ {' '.join(cmd)}", file=sys.stderr)
    return subprocess.run(cmd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True, type=Path)
    ap.add_argument("--remote", required=True)
    ap.add_argument("--rev", help="wasinix git rev that built this registry")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    # published filename -> {name, attr, drv_path}, emitted by make-index.py
    prov = json.loads((args.registry / "provenance.json").read_text())

    tmp = Path(tempfile.mkdtemp(prefix="wasix-publish-"))
    published_dir = tmp / "manifests"
    published_dir.mkdir()
    # a partial manifest view would defeat the immutability check, so only
    # "directory not found" (exit 3: first publish) may pass
    fetch = rclone("copy", f"{args.remote}/manifests", published_dir)
    if fetch.returncode == 3:
        print("no published manifests yet (first publish)", file=sys.stderr)
    elif fetch.returncode != 0:
        sys.exit(
            f"fetching published manifests failed (rclone exit {fetch.returncode})"
        )
    published = {
        p.name.removesuffix(".json"): json.loads(p.read_text())
        for p in published_dir.glob("*.json")
    }

    staging = tmp / "staging"
    conflicts, new = [], []
    manifests = dict(published)
    for whl in sorted((args.registry / "simple").glob("*/*.whl")):
        project = whl.parent.name
        sha = hashlib.sha256(whl.read_bytes()).hexdigest()
        prev = published.get(whl.name)
        if prev:
            if prev["sha256"] != sha:
                conflicts.append(f"{whl.name} (bump {project} in rels.json)")
            continue
        metadata = whl.with_name(whl.name + ".metadata").read_bytes()
        manifest = {
            "project": project,
            "sha256": sha,
            "metadata_sha256": hashlib.sha256(metadata).hexdigest(),
            "requires_python": make_index.requires_python(metadata),
            **prov.get(whl.name, {}),
        }
        if args.rev:
            manifest["wasinix_rev"] = args.rev
        pdir = staging / "simple" / project
        pdir.mkdir(parents=True, exist_ok=True)
        shutil.copy(whl, pdir / whl.name)
        (pdir / f"{whl.name}.metadata").write_bytes(metadata)
        (staging / "manifests").mkdir(parents=True, exist_ok=True)
        (staging / "manifests" / f"{whl.name}.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )
        manifests[whl.name] = manifest
        new.append(whl.name)

    if conflicts:
        sys.exit(
            "published wheels are immutable, refusing to overwrite:\n  "
            + "\n  ".join(conflicts)
        )

    # regenerate the HTML over everything published, old and new
    projects: dict[str, dict[str, dict]] = {}
    for fname, m in manifests.items():
        projects.setdefault(m["project"], {})[fname] = m
    for project, wheels in sorted(projects.items()):
        pdir = staging / "simple" / project
        pdir.mkdir(parents=True, exist_ok=True)
        anchors = [
            make_index.wheel_anchor(
                f, m["sha256"], m["metadata_sha256"], m["requires_python"]
            )
            for f, m in sorted(wheels.items())
        ]
        (pdir / "index.html").write_text(
            make_index.page(f"Links for {project}", anchors)
        )
    root = [f'    <a href="{p}/">{p}</a><br/>' for p in sorted(projects)]
    (staging / "simple" / "index.html").write_text(
        make_index.page("Simple index", root)
    )
    (staging / "index.html").write_text(make_index.landing())

    print(
        f"publishing {len(new)} new wheels "
        f"({len(manifests)} total across {len(projects)} projects)"
    )
    for n in new:
        print(f"  + {n}")
    # staging holds only new wheels plus regenerated HTML/manifests;
    # --ignore-times forces the HTML over unreliable S3 modtimes
    flags = ["--dry-run"] if args.dry_run else []
    if rclone("copy", "--ignore-times", *flags, staging, args.remote).returncode != 0:
        sys.exit("upload failed")


if __name__ == "__main__":
    main()
