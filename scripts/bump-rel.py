#!/usr/bin/env python3
"""Bump the publication release (+wasix.N) of shipped wheels or webcs.

For each package, increments its entry in rels.json (keyed by attr path then
upstream version, default 1), so the next publish republishes it under a new
version. Use after a rebuild changes contents at the same upstream version,
which both publishers otherwise refuse to overwrite.

Usage: bump-rel.py <key> [<key> ...]
Keys are rels.json attr paths (pythonRegistry.wheels.numpy, wasmerPackages.git),
bare names unique across the prefixes (numpy, git, python3.14), or fnmatch
globs over either form ('pythonRegistry.wheels.tok*', 'icu-data*'); quote
globs from the shell.
"""

import fnmatch
import json
import subprocess
import sys
from pathlib import Path

SYSTEM = "x86_64-linux"

PREFIXES = ("pythonRegistry.wheels.", "wasmerPackages.")


def resolve(name: str, versions: dict[str, str]) -> list[str]:
    if any(c in name for c in "*?["):
        hits = sorted(
            k
            for k in versions
            if fnmatch.fnmatchcase(k, name)
            or any(fnmatch.fnmatchcase(k, p + name) for p in PREFIXES)
        )
        if not hits:
            sys.exit(f"{name}: no rels-tracked package matches (see .#relVersions)")
        return hits
    if name in versions:
        return [name]
    hits = [p + name for p in PREFIXES if p + name in versions]
    if len(hits) == 1:
        return hits
    if not hits:
        sys.exit(f"{name}: not a rels-tracked package (see .#relVersions)")
    sys.exit(f"{name}: ambiguous, one of {', '.join(sorted(hits))}")


def main():
    names = sys.argv[1:]
    if not names:
        sys.exit("usage: bump-rel.py <key> [<key> ...]")

    repo = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
    )
    path = repo / "rels.json"
    rels = json.loads(path.read_text())

    # current upstream version of every rels-tracked package
    versions = json.loads(
        subprocess.run(
            [
                "nix",
                "eval",
                "--json",
                f".#legacyPackages.{SYSTEM}.relVersions",
            ],
            text=True,
            capture_output=True,
            check=True,
        ).stdout
    )

    keys = dict.fromkeys(
        key for name in dict.fromkeys(names) for key in resolve(name, versions)
    )

    bumps = []
    for key in keys:
        version = versions[key]
        cur = rels.get(key, {}).get(version, 1)
        rels.setdefault(key, {})[version] = cur + 1
        bumps.append(f"- {key} {version}: wasix.{cur} -> wasix.{cur + 1}")

    path.write_text(json.dumps(rels, indent=2, sort_keys=True) + "\n")
    print("\n".join(bumps))


if __name__ == "__main__":
    main()
