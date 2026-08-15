#!/usr/bin/env nix-shell
#! nix-shell -i python3 -p python3 uv git
"""Regenerate the PyPI pin set the hermetic anybuild template tests build against.

    pkgs/products/anybuild/update-mirror.py --force

anybuild's cross-wheel steps resolve against two indexes: the wasix overlay
(.#pythonRegistry) and a primary index standing in for PyPI. The tests serve
both over loopback, so the primary side has to be a fixed set of files rather
than a live resolution.

Resolves every listed template's requirements together, so one version per
project serves all of them and the resolution inside the test has no choice
left to make. Writes pkgs/overlay/packages/anybuild/tests/mirror-lock.json:
the pins plus, for each, the PyPI files a build can reach for (pure wheels,
cp313 linux wheels, abi3 wheels, and the sdist when there is no wheel) with
their URL and sha256, which the test's index fetches as plain fetchurls.

`templates` in the lock is the hand-edited input: which templates the hermetic
suite covers. Everything else in the file is generated. Needs network; CI only
reads the committed result.

Also the anybuild package's retentionHook, so a bump re-resolves the pins
against that release's examples/. The update driver runs every hook whenever
any target moved, so this no-ops unless the recorded anybuild version changed;
--force re-resolves anyway.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import urllib.request
from pathlib import Path

REPO = Path(
    subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()
)
LOCK = REPO / "pkgs/overlay/packages/anybuild/tests/mirror-lock.json"

# The version anybuild's python provider pins, and what the template sweep
# resolves against. Resolving per interpreter and unioning changes nothing here:
# the templates' own pins (python-flask's MarkupSafe==3.0.2) decide the set.
PYTHON_VERSION = "3.13"
# Both interpreters the serve check drives, since its host venv needs a wheel
# matching whichever one uv resolves against.
ABI_TAGS = {"cp313", "cp314"}

# uvx materializes pip to run the cross-platform install step, so the primary
# index has to serve it too.
TOOL_REQUIREMENTS = ["pip"]

# Linux wheel tags a build host can install.
LINUX_PLATFORMS = {
    "manylinux2014_x86_64",
    "manylinux_2_17_x86_64",
    "manylinux_2_28_x86_64",
    "manylinux_2_34_x86_64",
}
# Tags no build here installs, but which a universal resolution still has to
# see to evaluate a `sys_platform == 'win32'` marker.
MARKER_ONLY_PLATFORMS = {"win_amd64", "macosx_11_0_arm64"}


def sh(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def nix_build(installable: str) -> Path:
    out = sh(
        [
            "nix",
            "build",
            "--no-link",
            "--print-out-paths",
            "--accept-flake-config",
            installable,
        ],
        stdout=subprocess.PIPE,
    )
    return Path(out.stdout.strip())


def nix_eval(installable: str) -> str:
    out = sh(
        ["nix", "eval", "--raw", "--accept-flake-config", installable],
        stdout=subprocess.PIPE,
    )
    return out.stdout.strip()


def plan(anybuild: Path, project: Path) -> dict:
    out = sh(
        [str(anybuild / "bin/anybuild"), "plan", str(project), "--wasmer"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return json.loads(out.stdout)


def declared_requirements(project: Path) -> list[str]:
    reqs = []
    requirements = project / "requirements.txt"
    if requirements.is_file():
        reqs += [
            line.strip()
            for line in requirements.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        ]
    pyproject = project / "pyproject.toml"
    if pyproject.is_file():
        reqs += tomllib.loads(pyproject.read_text())["project"].get("dependencies", [])
    return reqs


def locked_pins(project: Path) -> list[str]:
    """A template shipping a uv.lock installs with `uv sync --locked`, which
    resolves nothing: the mirror has to carry those exact versions."""
    lock = project / "uv.lock"
    if not lock.is_file():
        return []
    return [
        f"{package['name']}=={package['version']}"
        for package in tomllib.loads(lock.read_text()).get("package", [])
        # The project itself has a virtual/editable source, not a registry one.
        if "registry" in package.get("source", {})
    ]


def resolve(requirements: list[str], workdir: Path) -> list[str]:
    """One universal resolution over the union, so the served set is consistent
    across templates and covers the markers a universal lock evaluates."""
    workdir.mkdir(parents=True, exist_ok=True)
    source = workdir / "union.in"
    source.write_text("\n".join(sorted(set(requirements))) + "\n")
    resolved = workdir / "union.txt"
    sh(
        [
            "uv",
            "pip",
            "compile",
            str(source),
            "--universal",
            f"--python-version={PYTHON_VERSION}",
            "--quiet",
            "-o",
            str(resolved),
        ]
    )
    pins = []
    for line in resolved.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        # Markers only steered the resolution; the pin itself is name==version.
        pins.append(re.split(r"\s*;", line, maxsplit=1)[0].strip())
    return pins


def wanted(filename: str) -> bool:
    if not filename.endswith(".whl"):
        return False
    tags = filename[: -len(".whl")].split("-")
    if len(tags) < 3:
        return False
    platform, abi = tags[-1], tags[-2]
    if platform == "any":
        return True
    platforms = set(platform.split("."))
    if platforms & LINUX_PLATFORMS:
        return abi in ABI_TAGS or abi in ("abi3", "none")
    return bool(platforms & MARKER_ONLY_PLATFORMS) and abi in ABI_TAGS


def select_files(project: str, version: str) -> list[dict]:
    url = f"https://pypi.org/pypi/{project}/{version}/json"
    with urllib.request.urlopen(url, timeout=60) as response:
        release = json.load(response)["urls"]
    # An sdist is the fallback for a project that publishes no usable wheel;
    # taking it alongside wheels would let pip prefer a source build.
    chosen = [entry for entry in release if wanted(entry["filename"])] or [
        entry for entry in release if entry["packagetype"] == "sdist"
    ]
    if not chosen:
        raise SystemExit(f"{project}=={version}: no installable file on PyPI")
    return [
        {
            "filename": entry["filename"],
            "url": entry["url"],
            "sha256": entry["digests"]["sha256"],
        }
        for entry in sorted(chosen, key=lambda entry: entry["filename"])
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--anybuild-src",
        help="anybuild checkout holding examples/ (default: build it from the flake)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="re-resolve even when the recorded anybuild version is current",
    )
    args = parser.parse_args()

    if not LOCK.is_file():
        raise SystemExit(f"{LOCK} is missing; seed it with a `templates` list")
    lock = json.loads(LOCK.read_text())
    names = lock["templates"]

    anybuild_version = nix_eval(".#nativePackages.anybuild.version")
    if lock.get("anybuild") == anybuild_version and not args.force:
        print(f"{LOCK.relative_to(REPO)} up to date (anybuild {anybuild_version})")
        return

    src = (
        Path(args.anybuild_src)
        if args.anybuild_src
        else nix_build(".#nativePackages.anybuild.src")
    )
    anybuild = nix_build(".#nativePackages.anybuild")

    requirements = {}
    providers = {}
    locked = []
    for name in names:
        project = src / "examples" / name
        if not project.is_dir():
            raise SystemExit(f"{name}: no examples/{name} in {src}")
        resolved = plan(anybuild, project)
        providers[name] = resolved["provider"]
        # The provider adds dependencies of its own on top of the project's
        # files: a server for a framework, mcp[cli], mkdocs itself.
        extras = resolved["config"].get("python_extra_dependencies") or []
        requirements[name] = sorted(set(extras + declared_requirements(project)))
        locked += locked_pins(project)
        print(
            f"  {name}: {' '.join(requirements[name]) or '(no dependencies)'}",
            file=sys.stderr,
        )

    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        union = [req for reqs in requirements.values() for req in reqs]
        pins = resolve(union, workdir / "templates")
        pins += resolve(TOOL_REQUIREMENTS, workdir / "tools")
    pins += locked

    dists = []
    for pin in sorted(set(pins)):
        project, _, version = pin.partition("==")
        if not version:
            raise SystemExit(f"unpinned requirement in the resolution: {pin!r}")
        print(f"  {pin}", file=sys.stderr)
        dists.append(
            {
                "project": project,
                "version": version,
                "files": select_files(project, version),
            }
        )

    LOCK.write_text(
        json.dumps(
            {
                "anybuild": anybuild_version,
                "templates": names,
                "providers": providers,
                "requirements": requirements,
                "dists": dists,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    total = sum(len(dist["files"]) for dist in dists)
    print(f"{LOCK.relative_to(REPO)}: {len(dists)} pins, {total} files")


if __name__ == "__main__":
    if shutil.which("uv") is None:
        raise SystemExit("uv is not on PATH")
    main()
