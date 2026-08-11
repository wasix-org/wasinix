#!/usr/bin/env python3
"""Update cargo-registry's untagged source, derived lockfile, and cargoHash."""

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(
    0,
    str(
        Path(
            subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                text=True,
                capture_output=True,
                check=True,
            ).stdout.strip()
        )
        / "scripts"
    ),
)
from updater_lib import gh, prefetch_github, raw_file, run_nix_update  # noqa: E402

PACKAGE = Path(__file__).parent
NIX = PACKAGE / "package.nix"
LOCK = PACKAGE / "Cargo.lock"
SOURCE_PIN = re.compile(
    r'(owner = "wasix-org";\s*repo = "cargo-registry";\s*rev = ")([0-9a-f]{40})(";\s*hash = ")(sha256-[^"]+)(";)',
    re.S,
)


def sync_source():
    text = NIX.read_text()
    match = SOURCE_PIN.search(text)
    if not match:
        raise SystemExit("cargo-registry source pin block not found")

    rev = gh("wasix-org/cargo-registry/commits/main")["sha"]
    if rev == match.group(2):
        return rev, False

    source_hash = prefetch_github("wasix-org", "cargo-registry", rev)
    NIX.write_text(
        text[: match.start()]
        + f"{match.group(1)}{rev}{match.group(3)}{source_hash}{match.group(5)}"
        + text[match.end() :]
    )
    return rev, True


def sync_lock(rev):
    upstream_lock = raw_file("wasix-org", "cargo-registry", rev, "Cargo.lock")
    result = subprocess.run(
        [sys.executable, str(PACKAGE / "derive-lock.py"), "/dev/stdin"],
        input=upstream_lock,
        text=True,
        capture_output=True,
        check=True,
    )
    sys.stderr.write(result.stderr)
    LOCK.write_text(result.stdout)


def main():
    rev, changed = sync_source()
    sync_lock(rev)
    run_nix_update([*sys.argv[1:], "--version=skip"])
    print(f"source {'updated to' if changed else 'already at'} {rev}")


if __name__ == "__main__":
    main()
