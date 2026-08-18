"""Validate a generated registry (tests.nix `integrity`): the root index lists
exactly the project dirs; every project-page anchor resolves to a file whose
sha256 matches the fragment; every wheel has a PEP 658 .metadata sidecar whose
hash matches data-core-metadata; no wheel on disk is missing from its page.

Usage: check-integrity.py <registry store path>
"""

import hashlib
import re
import sys
from pathlib import Path
from urllib.parse import unquote

# the wheel anchor's opening tag; its visible text is the interpreter label
# (plus a size span), so the filename comes from the href, not the link text.
ANCHOR = re.compile(r'<a href="([^"#]+)#sha256=([0-9a-f]{64})"([^>]*)>')
CORE_METADATA = re.compile(r'data-core-metadata="sha256=([0-9a-f]{64})"')
PROJECT_LINK = re.compile(r'<a href="([^"]+)/">')


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(msg: str) -> None:
    sys.exit(f"registry integrity: {msg}")


def anchors(page: str) -> dict[str, str]:
    return {unquote(href): digest for href, digest, _ in ANCHOR.findall(page)}


def check_native_view(root: Path, wheels: set[tuple[str, str]]) -> None:
    """The native view must list exactly the projects with a platform-tagged
    wheel, and reach the copies simple/ holds rather than carrying its own.

    Being the priority index is what binds a resolver to our versions, so a pure
    project listed here would block PyPI from supplying the version a consuming
    project asks for."""
    simple = root / "simple"
    native_dir = root / "native" / "simple"
    expected = {
        project
        for project, fname in wheels
        if fname[: -len(".whl")].rsplit("-", 1)[-1] != "any"
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


def main() -> None:
    simple = Path(sys.argv[1]) / "simple"
    listed = set(
        re.findall(r'<a href="([^"]+)/">', (simple / "index.html").read_text())
    )
    on_disk = {d.name for d in simple.iterdir() if d.is_dir()}
    if listed != on_disk:
        fail(f"root index vs project dirs differ: {sorted(listed ^ on_disk)}")

    total = 0
    served: set[tuple[str, str]] = set()
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
            served.add((pdir.name, fname))
            total += 1
        wheels_on_disk = {f.name for f in pdir.glob("*.whl")}
        if anchored != wheels_on_disk:
            fail(
                f"{pdir.name}: anchors vs wheels on disk differ: {sorted(anchored ^ wheels_on_disk)}"
            )

    if total == 0:
        fail("no wheels indexed at all")
    check_native_view(Path(sys.argv[1]), served)
    print(f"registry OK: {len(on_disk)} projects, {total} wheels")


if __name__ == "__main__":
    main()
