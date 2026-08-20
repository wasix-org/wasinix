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


def check_views(root: Path, wheels: list[tuple[str, Path]]) -> None:
    """simple/ must list exactly what PyPI cannot supply, and reach the wheels
    all/simple/ lists rather than carrying copies of its own.

    Being the priority index is what binds a resolver to our versions, so a
    project listed here that PyPI could have supplied blocks the version a
    consuming project asks for. A project missing here is the opposite defect:
    the resolver silently takes upstream's build of something we patched.

    A tweak that only skips a test leaves the wheel identical to upstream's, so
    it does not qualify; pkgs/lib/default.nix decides that."""
    simple = root / "simple"
    provenance = json.loads((root / "provenance.json").read_text())
    expected = {
        m["name"]
        for fname, m in provenance.items()
        if fname[: -len(".whl")].rsplit("-", 1)[-1] != "any" or m.get("supersedes")
    }
    listed = set(PROJECT_LINK.findall((simple / "index.html").read_text()))
    paged = {
        d.name for d in simple.iterdir() if d.is_dir() and (d / "index.html").is_file()
    }
    if listed != paged:
        fail(f"simple root index vs project pages differ: {sorted(listed ^ paged)}")
    if listed != expected:
        fail(
            "simple/ lists the wrong projects; one PyPI could supply blocks the "
            f"version a consumer asks for, and a missing one hides our patch: {sorted(listed ^ expected)}"
        )

    served = {}
    for project, path in wheels:
        served.setdefault(project, set()).add(path.name)
    for project in sorted(listed):
        page = (simple / project / "index.html").read_text()
        anchored = {unquote(href) for href, _, _ in ANCHOR.findall(page)}
        if anchored != served[project]:
            fail(
                f"simple/{project}: anchors vs wheels differ: {sorted(anchored ^ served[project])}"
            )


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
    every = root / "all" / "simple"
    # all/simple lists every wheel published; simple/ is the subset a resolver
    # should see beside PyPI, so the exhaustive walk reads the former
    listed = set(re.findall(r'<a href="([^"]+)/">', (every / "index.html").read_text()))
    on_disk = {d.name for d in simple.iterdir() if d.is_dir()}
    if listed != on_disk:
        fail(f"all/simple index vs project dirs differ: {sorted(listed ^ on_disk)}")

    wheels = []
    for pdir in sorted(simple.iterdir()):
        if not pdir.is_dir():
            continue
        # its anchors point back into simple/, so hrefs are compared by filename
        page = (every / pdir.name / "index.html").read_text()
        anchored = set()
        for href, digest, attrs in ANCHOR.findall(page):
            fname = unquote(href).rsplit("/", 1)[-1]
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
    check_views(root, wheels)
    check_requirements(wheels, wheel_deps)
    print(f"registry OK: {len(on_disk)} projects, {len(wheels)} wheels")


if __name__ == "__main__":
    main()
