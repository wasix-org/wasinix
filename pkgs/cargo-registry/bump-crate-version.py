#!/usr/bin/env python3
"""Restamp an unpacked .crate as <upstream>+wasix.N.

Only the version keys move; tomlkit round-trips every other byte of cargo's
normalized files unchanged. The main Cargo.toml must carry [package].version ==
<upstream>; Cargo.toml.orig and Cargo.lock are informational and edited only
when they carry that exact version -- a stale bundled lock or a workspace-
inherited version is left alone rather than mislabelled.

    bump-crate-version.py <dir> <crate> <upstream> <wasix-version>
"""

import sys

import tomlkit


def bump_manifest(doc, crate, expected, wasix_version):
    """Restamp [package].version if it is the crate's own concrete version."""
    pkg = doc.get("package")
    # A missing, workspace-inherited (non-str), or unexpected version is not ours
    # to restamp; the name guards against an unrelated [package] in an orig file.
    if (
        not pkg
        or pkg.get("name") not in (crate, None)
        or pkg.get("version") != expected
    ):
        return False
    pkg["version"] = wasix_version
    return True


def bump_lock(doc, crate, expected, wasix_version):
    """Restamp the crate's own [[package]] entry, if it is at the expected version."""
    for pkg in doc.get("package", []):
        if pkg.get("name") == crate:
            if pkg.get("version") != expected:
                return False
            pkg["version"] = wasix_version
            return True
    return False


def edit(path, bump, crate, expected, wasix_version):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = tomlkit.parse(fh.read())
    except FileNotFoundError:
        return False
    if not bump(doc, crate, expected, wasix_version):
        return False
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(tomlkit.dumps(doc))
    return True


def main():
    root, crate, expected, wasix_version = sys.argv[1:5]
    if not edit(f"{root}/Cargo.toml", bump_manifest, crate, expected, wasix_version):
        sys.exit(
            f"bump-crate-version: {root}/Cargo.toml has no [package].version == {expected!r}"
        )
    changed = ["Cargo.toml"]
    for name, bump in (("Cargo.toml.orig", bump_manifest), ("Cargo.lock", bump_lock)):
        if edit(f"{root}/{name}", bump, crate, expected, wasix_version):
            changed.append(name)
    print(
        f"bump-crate-version: {crate} {expected} -> {wasix_version} in {', '.join(changed)}"
    )


if __name__ == "__main__":
    main()
