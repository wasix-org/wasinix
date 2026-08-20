"""Check a wheel's published requirements are servable (python-wheels.nix `deps`).

Every requirement the wheel's own METADATA states must name a distribution the
registry serves. One that names something it cannot (a nixpkgs-internal module
name, a dependency dropped from the build but left in the metadata) makes `pip
install` fail to resolve, even though the import smoke-test passes: that test
runs off the installed closure rather than the published artifact.

Usage: python-wheel-deps.py <dist dir> <python version> <served name>...
"""

import re
import sys
import zipfile
from pathlib import Path

from packaging.markers import UndefinedEnvironmentName
from packaging.requirements import InvalidRequirement, Requirement

# What the shipped interpreter reports (wasix/python3 sets
# MACHDEP=wasix); a requirement gated on another platform is not ours to serve.
ENV = {
    "sys_platform": "wasix",
    "platform_system": "",
    "platform_machine": "wasm32",
    "os_name": "posix",
    "implementation_name": "cpython",
    "platform_python_implementation": "CPython",
}


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def main() -> None:
    dist, py_version, *served = sys.argv[1:]
    wheels = sorted(Path(dist).glob("*.whl"))
    if not wheels:
        sys.exit(f"wheel deps: no wheel in {dist}")

    env = dict(ENV, python_version=py_version, python_full_version=py_version)
    known = {normalize(n) for n in served}
    missing = []
    for wheel in wheels:
        with zipfile.ZipFile(wheel) as zf:
            meta = next(n for n in zf.namelist() if n.endswith(".dist-info/METADATA"))
            text = zf.read(meta).decode("utf-8", "replace")
        for line in text.splitlines():
            if not line.startswith("Requires-Dist:"):
                continue
            try:
                req = Requirement(line.split(":", 1)[1].strip())
            except InvalidRequirement:
                continue
            if req.marker is not None:
                try:
                    if not req.marker.evaluate(env):
                        continue
                except UndefinedEnvironmentName:
                    continue  # an extra's requirement: not installed by default
            if normalize(req.name) not in known:
                missing.append((wheel.name, req.name))

    if missing:
        for wheel, name in missing:
            print(
                f"{wheel}: requires '{name}', which the registry cannot serve",
                file=sys.stderr,
            )
        print(
            "-> pip resolves this wheel against the index, so every requirement must name "
            "something the registry serves; package it or drop it from the metadata.",
            file=sys.stderr,
        )
        sys.exit(1)
    print(f"OK {Path(dist).name}: {len(wheels)} wheel(s)")


if __name__ == "__main__":
    main()
