#!/usr/bin/env python3
"""Update yq's WASIX vendor hash after its package version moves."""

import re
import subprocess
import sys
from pathlib import Path

FAKE_HASH = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
HASH_PATTERN = re.compile(r'(?m)^(\s*vendorHash = ")([^"]+)(";\s*)$')
GOT_PATTERN = re.compile(r"\bgot:\s+(sha256-[A-Za-z0-9+/=]+)")

REPO = Path(
    subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()
)
PACKAGE = REPO / "pkgs/wasix/yq-go/package.nix"


def replace_hash(source, replacement):
    matches = list(HASH_PATTERN.finditer(source))
    if len(matches) != 1:
        raise SystemExit(f"expected one vendorHash in {PACKAGE.relative_to(REPO)}")
    current = matches[0].group(2)
    return HASH_PATTERN.sub(rf"\g<1>{replacement}\g<3>", source), current


def main():
    if len(sys.argv) not in (1, 3):
        raise SystemExit("expected either no versions or OLD_VERSION NEW_VERSION")

    profile = subprocess.run(
        ["nix", "eval", ".#defaultProfileName", "--raw", "--accept-flake-config"],
        cwd=REPO,
        text=True,
        stdout=subprocess.PIPE,
        check=True,
    ).stdout.strip()
    original = PACKAGE.read_text()
    with_fake_hash, current = replace_hash(original, FAKE_HASH)
    PACKAGE.write_text(with_fake_hash)
    try:
        result = subprocess.run(
            [
                "nix",
                "build",
                f".#legacyPackages.x86_64-linux.packages.wasix.{profile}.yq-go.goModules",
                "--no-link",
                "--accept-flake-config",
            ],
            cwd=REPO,
            text=True,
            capture_output=True,
        )
    finally:
        PACKAGE.write_text(original)

    output = result.stdout + "\n" + result.stderr
    match = GOT_PATTERN.search(output)
    if match is None:
        sys.stderr.write(output)
        raise SystemExit("yq module build did not report the expected vendor hash")

    updated = match.group(1)
    if updated == current:
        print("yq vendor hash up to date")
        return
    PACKAGE.write_text(replace_hash(original, updated)[0])
    print(f"yq vendor hash: {current} -> {updated}")


if __name__ == "__main__":
    main()
