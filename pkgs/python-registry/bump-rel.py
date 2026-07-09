#!/usr/bin/env python3
"""Bump the publication release (+wasix.N) of one or more shipped wheels.

For each wheel, increments its entry in pkgs/python-registry/rels.json (keyed by
upstream version, default 1), so the next publish republishes it under a new
+wasix.N filename. Use after a rebuild changes a wheel's contents at the same
upstream version, which the publisher otherwise refuses to overwrite.

Usage: bump-rel.py <wheel> [<wheel> ...]
Names are the project names as they appear in the registry
(pythonRegistry.wheelVersions).
"""

import json
import subprocess
import sys
from pathlib import Path

SYSTEM = "x86_64-linux"


def main():
    names = sys.argv[1:]
    if not names:
        sys.exit("usage: bump-rel.py <wheel> [<wheel> ...]")

    repo = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
    )
    path = repo / "pkgs/python-registry/rels.json"
    rels = json.loads(path.read_text())

    # current upstream version of every wheel in the registry
    versions = json.loads(
        subprocess.run(
            [
                "nix",
                "eval",
                "--json",
                f".#legacyPackages.{SYSTEM}.pythonRegistry.wheelVersions",
            ],
            text=True,
            capture_output=True,
            check=True,
        ).stdout
    )

    unknown = sorted(set(names) - versions.keys())
    if unknown:
        sys.exit(f"not wheels in the registry: {', '.join(unknown)}")

    bumps = []
    for name in dict.fromkeys(names):  # dedupe, keep order
        version = versions[name]
        cur = rels.get(name, {}).get(version, 1)
        rels.setdefault(name, {})[version] = cur + 1
        bumps.append(f"- {name} {version}: wasix.{cur} -> wasix.{cur + 1}")

    path.write_text(json.dumps(rels, indent=2, sort_keys=True) + "\n")
    print("\n".join(bumps))


if __name__ == "__main__":
    main()
