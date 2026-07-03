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

ANCHOR = re.compile(r'<a href="([^"#]+)#sha256=([0-9a-f]{64})"([^>]*)>([^<]+)</a>')
CORE_METADATA = re.compile(r'data-core-metadata="sha256=([0-9a-f]{64})"')


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(msg: str) -> None:
    sys.exit(f"registry integrity: {msg}")


def main() -> None:
    simple = Path(sys.argv[1]) / "simple"
    listed = set(re.findall(r'<a href="([^"]+)/">', (simple / "index.html").read_text()))
    on_disk = {d.name for d in simple.iterdir() if d.is_dir()}
    if listed != on_disk:
        fail(f"root index vs project dirs differ: {sorted(listed ^ on_disk)}")

    total = 0
    for pdir in sorted(simple.iterdir()):
        if not pdir.is_dir():
            continue
        page = (pdir / "index.html").read_text()
        anchored = set()
        for href, digest, attrs, text in ANCHOR.findall(page):
            if href != text:
                fail(f"{pdir.name}: link text {text!r} != href {href!r}")
            wheel = pdir / href
            if not wheel.is_file():
                fail(f"{pdir.name}: dangling link {href}")
            if sha256_of(wheel) != digest:
                fail(f"{pdir.name}: sha256 fragment mismatch for {href}")
            core = CORE_METADATA.search(attrs)
            if not core:
                fail(f"{pdir.name}: {href} has no data-core-metadata")
            metadata = pdir / f"{href}.metadata"
            if not metadata.is_file() or sha256_of(metadata) != core.group(1):
                fail(f"{pdir.name}: metadata sidecar missing or mismatched for {href}")
            anchored.add(href)
            total += 1
        wheels_on_disk = {f.name for f in pdir.glob("*.whl")}
        if anchored != wheels_on_disk:
            fail(f"{pdir.name}: anchors vs wheels on disk differ: {sorted(anchored ^ wheels_on_disk)}")

    if total == 0:
        fail("no wheels indexed at all")
    print(f"registry OK: {len(on_disk)} projects, {total} wheels")


if __name__ == "__main__":
    main()
