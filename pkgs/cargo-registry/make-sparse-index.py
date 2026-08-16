#!/usr/bin/env python3
"""Render a mint as a static cargo sparse index.

A sparse registry is a static file protocol, so a PR preview is just this
site behind any static host. Index entries derive from the same publish
metadata publish-crate.py computes, so the preview and the real publish
payload cannot drift.

    make-sparse-index.py <mint> <out> --base-url URL [--only name@vers ...]

Emits:
  <out>/config.json                     dl template pointing back at the site
  <out>/<prefix>/<name>                 newline-delimited index entries + cksum
  <out>/dl/<name>/<vers>.crate          the crate tarballs

A static index answers only for its own crates; unlike the real server it
cannot pass entries through to crates.io, so consumers name it as a separate
registry rather than a crates-io replacement.
"""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "publish_crate", Path(__file__).with_name("publish-crate.py")
)
publish_crate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(publish_crate)


def index_prefix(name: str) -> str:
    name = name.lower()
    if len(name) <= 2:
        return str(len(name))
    if len(name) == 3:
        return f"3/{name[0]}"
    return f"{name[:2]}/{name[2:4]}"


def index_entry(crate_path: Path) -> dict:
    """One index line, from the same metadata a publish would send."""
    meta = publish_crate.metadata_from_manifest(publish_crate.read_manifest(crate_path))
    deps = []
    for dep in meta["deps"]:
        entry = {
            "name": dep["name"],
            "req": dep["version_req"],
            "features": dep["features"],
            "optional": dep["optional"],
            "default_features": dep["default_features"],
            "target": dep["target"],
            "kind": dep["kind"],
        }
        if "registry" in dep:
            entry["registry"] = dep["registry"]
        if "explicit_name_in_toml" in dep:
            entry["name"] = dep["explicit_name_in_toml"]
            entry["package"] = dep["name"]
        deps.append(entry)
    return {
        "name": meta["name"],
        "vers": meta["vers"],
        "deps": deps,
        "cksum": hashlib.sha256(crate_path.read_bytes()).hexdigest(),
        "features": meta["features"],
        "yanked": False,
        "links": meta["links"],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mint", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--base-url", required=True)
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        help="restrict to these crate@wasixVersion entries",
    )
    args = parser.parse_args()

    manifest = json.loads((args.mint / "manifest.json").read_text())
    entries = manifest["crates"]
    if args.only:
        wanted = set(args.only)
        entries = [e for e in entries if f"{e['crate']}@{e['wasixVersion']}" in wanted]
        missing = wanted - {f"{e['crate']}@{e['wasixVersion']}" for e in entries}
        if missing:
            raise SystemExit(
                f"make-sparse-index: not in the mint: {', '.join(sorted(missing))}"
            )
    if not entries:
        raise SystemExit("make-sparse-index: nothing selected")

    base = args.base_url.rstrip("/")
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "config.json").write_text(
        json.dumps({"dl": base + "/dl/{crate}/{version}.crate"}) + "\n"
    )

    lines: dict[str, list[str]] = {}
    for entry in entries:
        crate_path = args.mint / "crates" / entry["crateFile"]
        record = index_entry(crate_path)
        lines.setdefault(record["name"], []).append(json.dumps(record))
        dl = args.out / "dl" / record["name"]
        dl.mkdir(parents=True, exist_ok=True)
        (dl / f"{record['vers']}.crate").write_bytes(crate_path.read_bytes())

    for name, records in lines.items():
        target = args.out / index_prefix(name) / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("\n".join(records) + "\n")
    print(f"sparse index: {len(entries)} entries for {len(lines)} crates")


if __name__ == "__main__":
    main()
