#!/usr/bin/env python3
"""Accumulating publisher for the static registry.

Copies new wheels from a freshly built structured-project registry
into the S3-compatible volume behind the index app and regenerates the index
HTML over everything published so far. Published wheel filenames are
immutable: a changed build with an existing filename stays unpublished until a
release-revisions.json bump gives it a new name, and nothing is ever deleted, so old
lockfiles keep resolving.

Volume layout (= the web root served by the app):
  index.html, simple/...     as in the nix output
  all/simple/...             the same listing over every wheel published
  packages.json              flat list of everything published so far
  manifests/<wheel>.json     {project, sha256, metadata_sha256, requires_python,
                              size, published (UTC date, frozen at first publish),
                              + provenance: attr, drv_path, wasinix_rev}
The manifests carry what HTML regeneration needs, so republishing never
downloads a wheel. Provenance lets `nix build
github:wasix-org/wasinix/<wasinix_rev>#<attr>` rebuild a given wheel.

Usage: publish.py --registry <path> --remote <rclone-remote:bucket>
                  --rclone <executable>
                  [--rev <wasinix git rev>] [--dry-run] [--withdraw-stale]
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
from datetime import datetime, timezone
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "make_index", Path(__file__).with_name("make-index.py")
)
make_index = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(make_index)


def rclone(executable, *args):
    # The wasmer S3 proxy fails signature verification on concurrent requests
    # (SignatureDoesNotMatch) and hangs on multipart uploads, so force serial,
    # single-part transfers. 5Gi is the S3 single-PutObject ceiling.
    cmd = [
        str(executable),
        "--quiet",
        "--transfers",
        "1",
        "--s3-upload-cutoff",
        "5Gi",
        *map(str, args),
    ]
    print(f"  $ {' '.join(cmd)}", file=sys.stderr)
    return subprocess.run(cmd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--registry", required=True, type=Path)
    ap.add_argument("--remote", required=True)
    ap.add_argument("--rclone", required=True, type=Path)
    ap.add_argument("--rev", help="wasinix git rev that built this registry")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument(
        "--refresh-listings",
        action="store_true",
        help="regenerate and upload the index pages even when no wheel is new, "
        "for a change in how make-index lists a project",
    )
    ap.add_argument(
        "--withdraw-stale",
        action="store_true",
        help="delete the listing of a project that no longer belongs in simple/, "
        "so it stops shadowing PyPI. Run by hand: a published URL that stops "
        "resolving breaks whoever resolved against it.",
    )
    args = ap.parse_args()

    # published filename -> release selector + provenance, emitted by make-index.py
    prov = json.loads((args.registry / "provenance.json").read_text())

    tmp = Path(tempfile.mkdtemp(prefix="wasix-publish-"))
    published_dir = tmp / "manifests"
    published_dir.mkdir()
    # a partial manifest view would defeat the immutability check, so only
    # "directory not found" (exit 3: first publish) may pass
    fetch = rclone(args.rclone, "copy", f"{args.remote}/manifests", published_dir)
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

    # stamped once at first publish, then frozen in the immutable manifest
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    staging = tmp / "staging"
    conflicts, new = [], []
    manifests = dict(published)
    for whl in sorted((args.registry / "simple").glob("*/*.whl")):
        project = whl.parent.name
        sha = hashlib.sha256(whl.read_bytes()).hexdigest()
        prev = published.get(whl.name)
        if prev:
            if prev["sha256"] != sha:
                wheel_prov = prov[whl.name]
                conflicts.append(
                    (
                        whl.name,
                        f"{wheel_prov['rel_key']}=={wheel_prov['version']}",
                    )
                )
            continue
        metadata = whl.with_name(whl.name + ".metadata").read_bytes()
        manifest = {
            "project": project,
            "sha256": sha,
            "metadata_sha256": hashlib.sha256(metadata).hexdigest(),
            "requires_python": make_index.requires_python(metadata),
            "size": whl.stat().st_size,
            "published": today,
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
        print(
            "published wheels are immutable; retaining the existing artifacts:\n  "
            + "\n  ".join(f"{wheel} ({spec})" for wheel, spec in conflicts),
            file=sys.stderr,
        )
        print(
            "bump-rel specs for the conflicting releases:\n  "
            + "\n  ".join(dict.fromkeys(spec for _, spec in conflicts)),
            file=sys.stderr,
        )

    # A registry rebuild can change existing wheel bytes through a nixpkgs,
    # toolchain, or runtime update. Those are not releases unless
    # release-revisions.json gave
    # them a new filename, so nothing is uploaded when nothing is new: the pages
    # are regenerated over every published wheel, and pushing all of them costs
    # a transfer each. The listings answer to make-index rather than to the
    # wheel set, though, so a change in how a project is listed reaches the
    # volume through --refresh-listings without waiting for a new wheel.
    if not new and not args.refresh_listings and not args.withdraw_stale:
        print("no new immutable wheels to publish")
        return

    # regenerate the HTML over everything published, old and new
    projects: dict[str, dict[str, dict]] = {}
    for fname, m in manifests.items():
        projects.setdefault(m["project"], {})[fname] = m
    pages = {}
    for project, wheels in sorted(projects.items()):
        pdir = staging / "simple" / project
        pdir.mkdir(parents=True, exist_ok=True)
        files = [
            (
                f,
                m["sha256"],
                m["metadata_sha256"],
                m["requires_python"],
                m.get("wasinix_rev"),
                m.get("attr"),
                m.get("size"),
                m.get("published"),
                m.get("source"),
            )
            for f, m in sorted(wheels.items())
        ]
        pages[project] = files
    # a manifest predating the field has no flag, so a project last published
    # before it existed stays out of simple/ until its next publish
    supersedes = {m["project"] for m in manifests.values() if m.get("supersedes")}
    primary = make_index.write_views(staging, pages, supersedes)
    (staging / "index.html").write_text(make_index.landing(projects))
    make_index.write_packages_json(
        staging / "packages.json",
        ((fname, m["sha256"]) for fname, m in manifests.items()),
    )

    print(
        f"publishing {len(new)} new wheels "
        f"({len(manifests)} total across {len(projects)} projects, "
        f"{len(primary)} listed in simple/)"
    )
    for n in new:
        print(f"  + {n}")
    # staging holds only new wheels plus regenerated HTML/manifests;
    # --ignore-times forces the HTML over unreliable S3 modtimes
    flags = ["--dry-run"] if args.dry_run else []
    if (
        rclone(
            args.rclone, "copy", "--ignore-times", *flags, staging, args.remote
        ).returncode
        != 0
    ):
        sys.exit("upload failed")

    # Published URLs are meant to keep resolving, so withdrawing one is a
    # deliberate act, not a step of every publish: a project that leaves simple/
    # keeps serving its old page until someone asks for it to go.
    if not args.withdraw_stale:
        return
    # The manifests name every project ever published, so the pages to withdraw
    # follow from them. The volume cannot enumerate simple/ anyway: rclone finds
    # no directories under it, though the objects are there and served.
    stale = sorted(set(projects) - set(primary))
    if not stale:
        print("no listings to withdraw")
        return
    withdrawn = []
    for project in stale:
        # a project that was never listed has no page, and deleting a missing
        # object reports failure, so one miss must not stop the rest
        page = f"{args.remote}/simple/{project}/index.html"
        if rclone(args.rclone, "deletefile", *flags, page).returncode == 0:
            withdrawn.append(project)
            print(f"  - simple/{project}/index.html")
    print(f"withdrew {len(withdrawn)} of {len(stale)} listing(s) PyPI can supply")


if __name__ == "__main__":
    main()
