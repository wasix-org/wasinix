"""Generate a static PEP 503 "simple" package index from built wheels.

Called by default.nix as: make-index.py <dists.json> <out>, where dists.json is
[{"name": <pname, for error messages>, "dist": <store path with the .whl>}, ...].

Emits, per PEP 503 (+ PEP 629 version meta, PEP 658/714 metadata files):
  <out>/simple/index.html               project list
  <out>/simple/<project>/index.html     file list with #sha256= anchors
  <out>/simple/<project>/<wheel>        the wheel itself (relative hrefs)
  <out>/simple/<project>/<wheel>.metadata   its core metadata, for resolvers
"""

import hashlib
import html
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path


def normalize(name: str) -> str:
    """PEP 503 project-name normalization."""
    return re.sub(r"[-_.]+", "-", name).lower()


def wheel_metadata(whl: Path) -> bytes:
    with zipfile.ZipFile(whl) as zf:
        names = [n for n in zf.namelist() if re.fullmatch(r"[^/]+\.dist-info/METADATA", n)]
        if len(names) != 1:
            sys.exit(f"{whl}: expected exactly one *.dist-info/METADATA, found {names}")
        return zf.read(names[0])


def requires_python(metadata: bytes) -> str | None:
    for line in metadata.decode("utf-8", "replace").splitlines():
        if not line.strip():
            break  # end of the RFC 822 header block
        key, _, value = line.partition(":")
        if key.strip().lower() == "requires-python":
            return value.strip()
    return None


def page(title: str, anchors: list[str]) -> str:
    lines = "\n".join(anchors)
    return f"""<!DOCTYPE html>
<html>
  <head>
    <meta name="pypi:repository-version" content="1.1"/>
    <title>{html.escape(title)}</title>
  </head>
  <body>
    <h1>{html.escape(title)}</h1>
{lines}
  </body>
</html>
"""


def main() -> None:
    dists = json.loads(Path(sys.argv[1]).read_text())
    out = Path(sys.argv[2])

    # normalized project name -> {wheel filename -> source path}
    projects: dict[str, dict[str, Path]] = {}
    for entry in dists:
        wheels = sorted(Path(entry["dist"]).glob("*.whl"))
        if not wheels:
            sys.exit(f"no .whl in dist output of '{entry['name']}': {entry['dist']}")
        for whl in wheels:
            project = normalize(whl.name.split("-", 1)[0])
            prev = projects.setdefault(project, {}).setdefault(whl.name, whl)
            if prev != whl and prev.read_bytes() != whl.read_bytes():
                sys.exit(f"conflicting contents for {whl.name}:\n  {prev}\n  {whl}")

    for project, wheels in sorted(projects.items()):
        pdir = out / "simple" / project
        pdir.mkdir(parents=True)
        anchors = []
        for fname, src in sorted(wheels.items()):
            shutil.copy(src, pdir / fname)
            metadata = wheel_metadata(src)
            (pdir / f"{fname}.metadata").write_bytes(metadata)
            md_digest = hashlib.sha256(metadata).hexdigest()
            attrs = ""
            rp = requires_python(metadata)
            if rp:
                attrs += f' data-requires-python="{html.escape(rp, quote=True)}"'
            # both attribute spellings: data-core-metadata (PEP 714) with the
            # data-dist-info-metadata (PEP 658) fallback for older resolvers.
            attrs += (
                f' data-core-metadata="sha256={md_digest}"'
                f' data-dist-info-metadata="sha256={md_digest}"'
            )
            digest = hashlib.sha256(src.read_bytes()).hexdigest()
            anchors.append(f'    <a href="{fname}#sha256={digest}"{attrs}>{fname}</a><br/>')
        (pdir / "index.html").write_text(page(f"Links for {project}", anchors))

    root = [f'    <a href="{p}/">{p}</a><br/>' for p in sorted(projects)]
    (out / "simple" / "index.html").write_text(page("Simple index", root))
    print(f"indexed {sum(map(len, projects.values()))} wheels across {len(projects)} projects")


if __name__ == "__main__":
    main()
