#!/usr/bin/env python3
# Merge several Cargo.lock files into one, keyed by (name, version, source).
# The wasix rust fork builds several workspaces (rustc, library, cargo,
# bootstrap), each with its own lock; fetchCargoVendor vendors exactly one lock,
# so we hand it the union. Dedup is by (name, version, source): the same crate
# from crates-io appears in many workspaces and collapses to one entry, while
# `libc 0.2.183` occurs under two sources (the WASIX git fork in library, the
# registry elsewhere) and both are kept so fetchCargoVendor lays them out in
# separate source dirs.
#
# Only name/version/source/checksum are emitted: those are all fetchCargoVendor
# reads (this merged lock only drives vendoring; x.py builds against each
# workspace's own lock). Dropping `dependencies` also makes the output a pure
# function of the package set, so it is independent of input-file order (the
# same crate can carry a different resolved dep list in two workspaces, which
# would otherwise make the hash order-sensitive).
import sys
import tomllib


def esc(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    out_path, lock_paths = sys.argv[1], sys.argv[2:]
    seen = {}
    for lf in lock_paths:
        with open(lf, "rb") as f:
            doc = tomllib.load(f)
        for pkg in doc.get("package", []):
            key = (pkg["name"], pkg["version"], pkg.get("source"))
            prev = seen.get(key)
            if prev is not None:
                if pkg.get("checksum") != prev.get("checksum"):
                    sys.exit(f"conflicting checksum for {key}")
                continue
            seen[key] = pkg

    pkgs = sorted(
        seen.values(), key=lambda p: (p["name"], p["version"], p.get("source") or "")
    )
    lines = ["version = 4", "", ""]
    for pkg in pkgs:
        lines.append("[[package]]")
        lines.append(f"name = {esc(pkg['name'])}")
        lines.append(f"version = {esc(pkg['version'])}")
        if pkg.get("source") is not None:
            lines.append(f"source = {esc(pkg['source'])}")
        if "checksum" in pkg:
            lines.append(f"checksum = {esc(pkg['checksum'])}")
        lines.append("")
    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
