#!/usr/bin/env python3
# Bump wasix-libc, then re-derive the pins that follow from it.
#
# libc.nix pins the wasi/wasix witx specs (git submodules of wasix-libc)
# separately from the libc src, because a submodule is not part of the source
# tarball. A stale pin fails the build with undeclared __wasi_* functions, and
# the correct rev is whatever the new tag points its submodule at, so this is
# package knowledge and lives next to the pin it edits.
#
# Invoked as `update.py <nix-update ...>`: the driver passes the command
# nix-update-script produced, so the package declares its bump once.

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
from updater_lib import REPO, gh, prefetch_github, run_nix_update  # noqa: E402

LIBC = REPO / "pkgs/toolchain/sysroot/libc.nix"
SUBMODULES = [
    ("tools/wasi-headers/WASI", "WebAssembly", "WASI"),
    ("tools/wasix-headers/WASI", "wasix-org", "wasix-witx"),
]


def sync_witx():
    text = LIBC.read_text()
    tag = "v" + re.search(r'\bversion = "([^"]+)"', text).group(1)
    bumped = []
    for sub, owner, repo in SUBMODULES:
        sha = gh(f"wasix-org/wasix-libc/contents/{sub}?ref={tag}")["sha"]
        m = re.search(
            rf'repo = "{repo}";\s*\n\s*rev = "([^"]+)";\s*\n\s*hash = "([^"]+)"', text
        )
        if not m:
            raise SystemExit(f"{repo}: witx pin block not found in libc.nix")
        if m.group(1) == sha:
            continue
        new_hash = prefetch_github(owner, repo, sha)
        text = text.replace(m.group(1), sha, 1).replace(m.group(2), new_hash, 1)
        bumped.append(f"{repo} {sha[:12]}")
    if not bumped:
        return None
    LIBC.write_text(text)
    return ", ".join(bumped)


def main():
    run_nix_update(sys.argv[1:])
    synced = sync_witx()
    # No " -> ": the driver scans stdout backwards for an outcome line and must
    # land on nix-update's, not this one.
    print(f"witx pins synced: {synced}" if synced else "witx pins ok")


if __name__ == "__main__":
    main()
