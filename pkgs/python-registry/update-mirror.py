#!/usr/bin/env python3
"""Regenerate the vendored PyPI wheel set the registry tests resolve against.

    pkgs/python-registry/update-mirror.py

The registry serves only what PyPI cannot (native or wasix-patched wheels); a
resolver installing from it beside PyPI takes every pure dependency from PyPI.
The nix-sandbox tests have no network, so this pins the pure wheels they need
and mirror.nix serves them on loopback. One universal resolve per closure
project collects its pins; a pin PyPI ships as py3-none-any is pure and enters
the lock (its native pins are the registry's job). Writes mirror-lock.json:
{project, version, files:[{filename, url, sha256}]}, fetched by mirror.nix as
plain fetchurls. Needs network; CI reads only the committed result.
"""

import json
import re
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
CATALOG = REPO / "pkgs/python/wheels/default.nix"
LOCK = HERE / "mirror-lock.json"
PYTHON_VERSION = "3.13"

# catalog attr -> PyPI project. Only where they differ: a version-suffixed alias
# resolves to the base project, and a rename maps to its distribution name.
ALIASES = {
    "protobuf4": "protobuf",
    "protobuf5": "protobuf",
    "protobuf6": "protobuf",
    "chardet_5": "chardet",
    "pytest_7": "pytest",
    "pytest_8_3": "pytest",
    "pytest_9_0": "pytest",
    "pytest-asyncio_0": "pytest-asyncio",
}
# Attrs that are not on PyPI under their own name (wasix-only or renamed builds);
# their pure dependencies arrive through another project's resolve.
SKIP = {
    "jqpy",
    "burner-redis",
    "dbt-core-experimental-parser",
    "envier",
    "chardet_5",
}
# The two default.nix sections whose wheels are pure and unmodified; every other
# section builds a native wheel the registry serves. Section headers are box
# rules, so the catalog names its own pure set.
PURE_SECTIONS = {
    "pure-python (no C extension)",
    "LLM / agent SDKs (pure-python; transitive deps auto-build + auto-publish)",
}
# Pure catalog projects the registry serves anyway, so PyPI must not shadow them:
# a project whose overlay changes the build (supersedesPyPI), and protobuf, whose
# pure-section entry still builds the native upb backend.
PURE_BUT_SERVED = {
    "urllib3",
    "attrs",
    "pydantic",
    "httpcore",
    "httpx",
    "starlette",
    "docutils",
    "textual",
    "langchain-core",
    "langchain",
    "langflow",
    "protobuf",
}


def registry_served() -> set[str]:
    """Projects the registry serves (native or patched), which the mirror must
    not carry: a resolver taking PyPI's build of one would shadow ours. Native
    is every catalog section but the two pure ones; PURE_BUT_SERVED adds the
    pure exceptions."""
    text = CATALOG.read_text()
    served = set(PURE_BUT_SERVED)
    section = None
    for line in text.splitlines():
        header = re.search(r"──\s*(.+?)\s*──", line)
        if header:
            section = header.group(1)
            continue
        attr = re.search(r'attr\s*=\s*"([^"]+)"', line)
        if attr and section is not None and section not in PURE_SECTIONS:
            served.add(
                ALIASES.get(attr.group(1), attr.group(1)).lower().replace("_", "-")
            )
    return served


def closure_projects() -> list[str]:
    """Every project resolve-sweep resolves: the registry's full runtime closure,
    read from its wheelVersions passthru so the mirror covers exactly what the
    sweep walks (the catalog alone misses transitive members like flit-core or
    types-urllib3). A resolve that fails or ships no pure wheel is skipped."""
    out = subprocess.run(
        [
            "nix",
            "eval",
            "--raw",
            "--accept-flake-config",
            ".#legacyPackages.x86_64-linux.artifacts.registry.python.wheelVersions",
            "--apply",
            'v: builtins.concatStringsSep " " (builtins.attrNames v)',
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    names = set(out.stdout.split())
    return sorted(n for n in names if n not in SKIP)


def resolve(project: str) -> list[tuple[str, str]]:
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "in.txt"
        src.write_text(project + "\n")
        out = Path(d) / "out.txt"
        proc = subprocess.run(
            [
                "uv",
                "pip",
                "compile",
                str(src),
                "--universal",
                f"--python-version={PYTHON_VERSION}",
                "--quiet",
                "-o",
                str(out),
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            print(
                f"  skip {project}: {proc.stderr.strip().splitlines()[-1:]}",
                file=sys.stderr,
            )
            return []
        pins = []
        for line in out.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if not line or line.startswith("-"):
                continue
            m = re.match(r"([A-Za-z0-9_.-]+)==([^\s;]+)", line)
            if m:
                pins.append((m.group(1), m.group(2)))
        return pins


def pure_files(project: str, version: str) -> list[dict]:
    """PyPI's py3-none-any wheels for this release, or [] if it ships none
    (a native project, which the registry serves instead)."""
    url = f"https://pypi.org/pypi/{project}/{version}/json"
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            release = json.load(response)["urls"]
    except Exception as e:
        print(f"  no PyPI metadata for {project}=={version}: {e}", file=sys.stderr)
        return []
    files = []
    for entry in release:
        name = entry["filename"]
        if not name.endswith(".whl"):
            continue
        if name[: -len(".whl")].rsplit("-", 1)[-1] != "any":
            continue
        files.append(
            {
                "filename": name,
                "url": entry["url"],
                "sha256": entry["digests"]["sha256"],
            }
        )
    return sorted(files, key=lambda f: f["filename"])


def main() -> None:
    projects = closure_projects()
    print(
        f"resolving {len(projects)} closure projects for their pure closures",
        file=sys.stderr,
    )
    wanted: dict[str, set[str]] = {}
    for i, project in enumerate(projects, 1):
        for name, version in resolve(project):
            wanted.setdefault(name.lower().replace("_", "-"), set()).add(version)
        if i % 25 == 0:
            print(f"  resolved {i}/{len(projects)}", file=sys.stderr)

    served = registry_served()
    dists = []
    for project in sorted(wanted):
        if project in served:
            continue
        for version in sorted(wanted[project]):
            files = pure_files(project, version)
            if files:
                dists.append({"project": project, "version": version, "files": files})

    LOCK.write_text(
        json.dumps(
            {"python_version": PYTHON_VERSION, "dists": dists}, indent=2, sort_keys=True
        )
        + "\n"
    )
    print(
        f"wrote {LOCK.relative_to(REPO)}: "
        f"{len(dists)} pure dists, {sum(len(d['files']) for d in dists)} files",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
