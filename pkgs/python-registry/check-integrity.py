"""Validate a generated registry (tests.nix `integrity`): the root index lists
exactly the project dirs; every project-page anchor resolves to a file whose
sha256 matches the fragment; every wheel has a PEP 658 .metadata sidecar whose
hash matches data-core-metadata; no wheel on disk is missing from its page;
packages.json lists exactly the served wheels; and every wheel's Requires-Dist
is satisfiable from the index alone, on each interpreter the wheel installs on.

Usage: check-integrity.py <registry store path> <python-wheel-deps.py path>
"""

import hashlib
import importlib.util
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote

from packaging.markers import UndefinedEnvironmentName
from packaging.requirements import InvalidRequirement, Requirement
from packaging.specifiers import SpecifierSet
from packaging.version import Version

# the wheel anchor's opening tag; its visible text is the interpreter label
# (plus a size span), so the filename comes from the href, not the link text.
ANCHOR = re.compile(r'<a href="([^"#]+)#sha256=([0-9a-f]{64})"([^>]*)>')
CORE_METADATA = re.compile(r'data-core-metadata="sha256=([0-9a-f]{64})"')
CP_TAG = re.compile(r"cp(\d)(\d+)")
PROJECT_LINK = re.compile(r'<a href="([^"]+)/">')


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(msg: str) -> None:
    sys.exit(f"registry integrity: {msg}")


def load_module(path: str):
    spec = importlib.util.spec_from_file_location("wheel_deps", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# {name}-{version}[-{build}]-{python}-{abi}-{platform}.whl: the build tag is
# optional and follows the version, so the compatibility tags read from the right.
def wheel_tags(fname: str) -> tuple[str, list[str], str]:
    parts = fname[: -len(".whl")].split("-")
    return parts[1], parts[-3].split("."), parts[-2]


def installs_on(pytags: list[str], abi: str, interp: tuple[int, int]) -> bool:
    major, minor = interp
    for tag in pytags:
        if tag in (f"py{major}", f"py{major}{minor}", f"cp{major}{minor}"):
            return True
        m = CP_TAG.fullmatch(tag)
        # an abi3 wheel's python tag is a floor: it loads on every later CPython
        if m and abi == "abi3" and (int(m[1]), int(m[2])) <= interp:
            return True
    return False


def anchors(page: str) -> dict[str, str]:
    return {unquote(href): digest for href, digest, _ in ANCHOR.findall(page)}


def check_native_view(root: Path, wheels: list[tuple[str, Path]]) -> None:
    """The native view must list exactly the projects with a platform-tagged
    wheel, and reach the copies simple/ holds rather than carrying its own.

    Being the priority index is what binds a resolver to our versions, so a pure
    project listed here would block PyPI from supplying the version a consuming
    project asks for."""
    simple = root / "simple"
    native_dir = root / "native" / "simple"
    expected = {
        project
        for project, path in wheels
        if path.name[: -len(".whl")].rsplit("-", 1)[-1] != "any"
    }
    listed = set(PROJECT_LINK.findall((native_dir / "index.html").read_text()))
    on_disk = {d.name for d in native_dir.iterdir() if d.is_dir()}
    if listed != on_disk:
        fail(f"native root index vs project dirs differ: {sorted(listed ^ on_disk)}")
    if listed != expected:
        fail(
            "native view lists the wrong projects; a pure one here blocks PyPI: "
            f"{sorted(listed ^ expected)}"
        )

    for project in sorted(listed):
        page = (native_dir / project / "index.html").read_text()
        # the native anchors are relative to simple/, so compare by filename
        anchored = {href.rsplit("/", 1)[-1]: d for href, d in anchors(page).items()}
        served = anchors((simple / project / "index.html").read_text())
        if anchored != served:
            fail(
                f"native/{project}: files differ from simple/: {sorted(set(anchored) ^ set(served))}"
            )
        for href in re.findall(r'<a href="([^"#]+)#sha256=', page):
            if not (native_dir / project / unquote(href)).resolve().is_file():
                fail(f"native/{project}: {href} does not resolve into simple/")


def parse_metadata(path: Path) -> tuple[SpecifierSet | None, list[Requirement]]:
    """(Requires-Python, Requires-Dist) from a PEP 658 sidecar."""
    bound = None
    reqs = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("Requires-Python:"):
            bound = SpecifierSet(line.split(":", 1)[1].strip())
        elif line.startswith("Requires-Dist:"):
            try:
                reqs.append(Requirement(line.split(":", 1)[1].strip()))
            except InvalidRequirement:
                continue
    return bound, reqs


def check_packages_json(root: Path, wheels: list[tuple[str, Path]]) -> None:
    """wasmer-compat reads this JSONL to decide which projects the index covers,
    and skips any line it cannot parse, so a wrong shape degrades to an empty
    index rather than an error."""
    listed = set()
    for n, line in enumerate(
        root.joinpath("packages.json").read_text().splitlines(), 1
    ):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as e:
            fail(f"packages.json line {n} is not JSON: {e}")
        if "filename" not in entry:
            fail(f"packages.json line {n} has no 'filename' key")
        listed.add(entry["filename"])
    on_disk = {path.name for _, path in wheels}
    if listed != on_disk:
        fail(f"packages.json vs wheels on disk differ: {sorted(listed ^ on_disk)}")


def check_requirements(wheels: list[tuple[str, Path]], wheel_deps) -> None:
    interps = set()
    for _, path in wheels:
        _, pytags, abi = wheel_tags(path.name)
        # an abi3 tag names the floor it was built against, not an interpreter
        # the index serves, so cp37-abi3 must not invent a python 3.7
        if abi == "abi3":
            continue
        for tag in pytags:
            if m := CP_TAG.fullmatch(tag):
                interps.add((int(m[1]), int(m[2])))
    if not interps:
        fail("no cp-tagged wheel, so the served interpreters cannot be derived")

    meta = {
        path: parse_metadata(path.with_name(f"{path.name}.metadata"))
        for _, path in wheels
    }

    # interpreter -> project -> versions installable on it. A resolver takes a
    # wheel only where both gates admit it, so a py3-none-any wheel is limited by
    # its Requires-Python alone.
    served: dict[tuple[int, int], dict[str, list[Version]]] = {i: {} for i in interps}
    targets: dict[Path, list[tuple[int, int]]] = {}
    for project, path in wheels:
        version, pytags, abi = wheel_tags(path.name)
        bound = meta[path][0]
        applies = sorted(
            i
            for i in interps
            if installs_on(pytags, abi, i)
            and (bound is None or bound.contains(f"{i[0]}.{i[1]}"))
        )
        if not applies:
            fail(f"{project}: {path.name} installs on none of {sorted(interps)}")
        targets[path] = applies
        for i in applies:
            served[i].setdefault(project, []).append(Version(version))

    unmet = []
    for project, path in wheels:
        reqs = meta[path][1]
        for interp in targets[path]:
            py = f"{interp[0]}.{interp[1]}"
            env = dict(wheel_deps.ENV, python_version=py, python_full_version=py)
            for req in reqs:
                if req.marker is not None:
                    try:
                        if not req.marker.evaluate(env):
                            continue
                    except UndefinedEnvironmentName:
                        continue  # an extra's requirement: not installed by default
                have = served[interp].get(wheel_deps.normalize(req.name), [])
                # filter() applies pip's rule: prefer stable, fall back to a
                # pre-release only when nothing else matches.
                if not any(req.specifier.filter(have)):
                    unmet.append((path.name, py, str(req), have))

    if unmet:
        for fname, py, req, have in unmet:
            state = (
                f"served: {', '.join(sorted(map(str, have)))}" if have else "not served"
            )
            print(f"{fname} (python {py}): requires '{req}' ({state})", file=sys.stderr)
        print(
            "-> a resolver installing from this index sees no other source, so every "
            "requirement must be satisfiable from it; serve the missing version or fix "
            "the requiring package's metadata.",
            file=sys.stderr,
        )
        fail(f"{len(unmet)} unsatisfiable requirement(s)")


def main() -> None:
    root = Path(sys.argv[1])
    wheel_deps = load_module(sys.argv[2])
    simple = root / "simple"
    listed = set(
        re.findall(r'<a href="([^"]+)/">', (simple / "index.html").read_text())
    )
    on_disk = {d.name for d in simple.iterdir() if d.is_dir()}
    if listed != on_disk:
        fail(f"root index vs project dirs differ: {sorted(listed ^ on_disk)}")

    wheels = []
    for pdir in sorted(simple.iterdir()):
        if not pdir.is_dir():
            continue
        page = (pdir / "index.html").read_text()
        anchored = set()
        for href, digest, attrs in ANCHOR.findall(page):
            fname = unquote(href)
            if "+wasix." not in fname:
                fail(f"{pdir.name}: {fname} lacks the +wasix.N publication release")
            wheel = pdir / fname
            if not wheel.is_file():
                fail(f"{pdir.name}: dangling link {href}")
            if sha256_of(wheel) != digest:
                fail(f"{pdir.name}: sha256 fragment mismatch for {fname}")
            core = CORE_METADATA.search(attrs)
            if not core:
                fail(f"{pdir.name}: {fname} has no data-core-metadata")
            metadata = pdir / f"{fname}.metadata"
            if not metadata.is_file() or sha256_of(metadata) != core.group(1):
                fail(f"{pdir.name}: metadata sidecar missing or mismatched for {fname}")
            anchored.add(fname)
            wheels.append((pdir.name, wheel))
        wheels_on_disk = {f.name for f in pdir.glob("*.whl")}
        if anchored != wheels_on_disk:
            fail(
                f"{pdir.name}: anchors vs wheels on disk differ: {sorted(anchored ^ wheels_on_disk)}"
            )

    if not wheels:
        fail("no wheels indexed at all")
    check_packages_json(root, wheels)
    check_native_view(root, wheels)
    check_requirements(wheels, wheel_deps)
    print(f"registry OK: {len(on_disk)} projects, {len(wheels)} wheels")


if __name__ == "__main__":
    main()
