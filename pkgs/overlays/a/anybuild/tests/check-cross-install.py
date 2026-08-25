#!/usr/bin/env python3
"""Check what anybuild cross-installed into each built template.

    check-cross-install.py <expectations.json> <built templates root>

expectations.json is {pythonVersion, crossInstalled, staticSite}: the templates
whose python provider serves off a wasix venv, and those where python only runs
at build time and the site is served statically.
"""

import json
import pathlib
import sys

expectations = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
version = expectations["pythonVersion"]
failures = []


def project(name: str) -> str:
    return name.replace("_", "-").lower()


for name in expectations["crossInstalled"]:
    site = (
        root
        / name
        / ".anybuild/local/build/opt/venv/lib"
        / f"python{version}/site-packages"
    )
    if not site.is_dir():
        failures.append(f"{name}: no cross-compiled site-packages at {site}")
        continue

    versions = {}
    for dist in site.glob("*.dist-info"):
        dist_project, _, dist_version = dist.name[: -len(".dist-info")].rpartition("-")
        versions[project(dist_project)] = dist_version
    if not versions:
        failures.append(f"{name}: cross site-packages holds no distributions")
        continue

    # Every shared object in the serve tree must be a wasm module, which only the
    # wasix overlay index publishes; an abi3 file name carries no platform tag,
    # so the magic is the honest check. Its distribution must in turn be a
    # +wasix.N release.
    natives = 0
    for library in site.rglob("*.so"):
        natives += 1
        with library.open("rb") as handle:
            if handle.read(4) != b"\0asm":
                failures.append(
                    f"{name}: {library.relative_to(site)} is not a wasm module"
                )
        owner = project(library.relative_to(site).parts[0])
        owner_version = versions.get(owner)
        if owner_version is not None and "+wasix." not in owner_version:
            failures.append(
                f"{name}: {owner} {owner_version} ships a native extension but is "
                "not a wasix release"
            )
    print(f"  {name}: {len(versions)} distributions, {natives} wasm extensions")

for name in expectations["staticSite"]:
    index = root / name / ".anybuild/local/build/opt/static_app/index.html"
    if not index.is_file() or not index.stat().st_size:
        failures.append(f"{name}: python built no static site at {index}")
        continue
    print(f"  {name}: static site generated")

if failures:
    sys.exit("\n".join(failures))
