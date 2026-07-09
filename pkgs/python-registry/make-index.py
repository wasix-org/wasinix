"""Generate a static PEP 503 "simple" package index from built wheels.

Called by default.nix as: make-index.py <dists.json> <out>, where dists.json is
[{"name", "version", "rel", "dist" = store path with the .whl}, ...].

Every wheel is republished as <version>+wasix.<rel> (PEP 440 local version,
the publication release: same upstream version, our Nth build of it), keeping
filename, dist-info dir, METADATA and RECORD consistent.

Emits, per PEP 503 (+ PEP 629 version meta, PEP 658/714 metadata files):
  <out>/simple/index.html               project list
  <out>/simple/<project>/index.html     file list with #sha256= anchors
  <out>/simple/<project>/<wheel>        the wheel itself (relative hrefs)
  <out>/simple/<project>/<wheel>.metadata   its core metadata, for resolvers
"""

import base64
import csv
import hashlib
import html
import io
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path
from urllib.parse import quote


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


def record_hash(data: bytes) -> str:
    # RECORD hash spelling (PEP 376/427): urlsafe base64, no padding
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip("=")


def bump_metadata_version(metadata: bytes, version: str, new_version: str) -> bytes:
    lines = metadata.split(b"\n")
    for i, line in enumerate(lines):
        if not line.strip():
            break  # end of headers, no Version seen
        key, _, value = line.partition(b":")
        if key.strip().lower() == b"version":
            if value.strip().decode() != version:
                sys.exit(f"METADATA Version {value.strip().decode()!r} != filename version {version!r}")
            lines[i] = f"Version: {new_version}".encode()
            return b"\n".join(lines)
    sys.exit("METADATA has no Version header")


def rewrite_wheel(src: Path, dest_dir: Path, rel: int) -> Path:
    """Copy the wheel with +wasix.<rel> appended to its version."""
    name, version, rest = src.name.split("-", 2)
    if "+" in version:
        sys.exit(f"{src.name}: already carries a local version")
    new_version = f"{version}+wasix.{rel}"

    with zipfile.ZipFile(src) as zin:
        dist_infos = {n.split("/", 1)[0] for n in zin.namelist() if re.match(r"[^/]+\.dist-info/", n)}
        if len(dist_infos) != 1:
            sys.exit(f"{src.name}: expected exactly one *.dist-info dir, found {sorted(dist_infos)}")
        old_di = dist_infos.pop()
        if not old_di.endswith(f"-{version}.dist-info"):
            sys.exit(f"{src.name}: dist-info dir {old_di!r} does not match filename version {version!r}")
        new_di = old_di.removesuffix(f"-{version}.dist-info") + f"-{new_version}.dist-info"
        rename = lambda n: new_di + n.removeprefix(old_di) if n.startswith(f"{old_di}/") else n

        entries = [(rename(i.filename), i, zin.read(i.filename)) for i in zin.infolist()]

    files = {n: data for n, _, data in entries}
    files[f"{new_di}/METADATA"] = bump_metadata_version(files[f"{new_di}/METADATA"], version, new_version)

    # RECORD: renamed paths, plus the refreshed METADATA hash/size
    rows = list(csv.reader(io.StringIO(files[f"{new_di}/RECORD"].decode())))
    for row in rows:
        row[0] = rename(row[0])
        if row[0] == f"{new_di}/METADATA":
            row[1] = record_hash(files[row[0]])
            row[2] = str(len(files[row[0]]))
    buf = io.StringIO(newline="")
    csv.writer(buf, lineterminator="\n").writerows(rows)
    files[f"{new_di}/RECORD"] = buf.getvalue().encode()

    dest = dest_dir / f"{name}-{new_version}-{rest}"
    with zipfile.ZipFile(dest, "w") as zout:
        for newname, info, _ in entries:
            zi = zipfile.ZipInfo(newname, date_time=info.date_time)
            zi.compress_type = info.compress_type
            zi.external_attr = info.external_attr
            zout.writestr(zi, files[newname])
    return dest


def wheel_anchor(fname: str, digest: str, md_digest: str, rp: str | None) -> str:
    attrs = ""
    if rp:
        attrs += f' data-requires-python="{html.escape(rp, quote=True)}"'
    # both attribute spellings: data-core-metadata (PEP 714) with the
    # data-dist-info-metadata (PEP 658) fallback for older resolvers.
    attrs += (
        f' data-core-metadata="sha256={md_digest}"'
        f' data-dist-info-metadata="sha256={md_digest}"'
    )
    return f'    <a href="{quote(fname)}#sha256={digest}"{attrs}>{fname}</a><br/>'


def landing() -> str:
    # for humans; pip only ever sees simple/
    return page(
        "WASIX Python package index",
        [
            "    <p>pip install --index-url &lt;this url&gt;/simple &lt;package&gt;</p>",
            '    <a href="simple/">simple/</a>',
        ],
    )


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

    # normalized project name -> {wheel filename -> rewritten path}
    projects: dict[str, dict[str, Path]] = {}
    tmp = Path(tempfile.mkdtemp(prefix="wasix-wheels-"))
    for i, entry in enumerate(dists):
        wheels = sorted(Path(entry["dist"]).glob("*.whl"))
        if not wheels:
            sys.exit(f"no .whl in dist output of '{entry['name']}': {entry['dist']}")
        entry_dir = tmp / str(i)
        entry_dir.mkdir()
        for whl in wheels:
            moved = rewrite_wheel(whl, entry_dir, entry["rel"])
            project = normalize(moved.name.split("-", 1)[0])
            prev = projects.setdefault(project, {}).setdefault(moved.name, moved)
            if prev != moved and prev.read_bytes() != moved.read_bytes():
                sys.exit(f"conflicting contents for {moved.name}:\n  {prev}\n  {moved}")

    for project, wheels in sorted(projects.items()):
        pdir = out / "simple" / project
        pdir.mkdir(parents=True)
        anchors = []
        for fname, src in sorted(wheels.items()):
            shutil.copy(src, pdir / fname)
            metadata = wheel_metadata(src)
            (pdir / f"{fname}.metadata").write_bytes(metadata)
            md_digest = hashlib.sha256(metadata).hexdigest()
            digest = hashlib.sha256(src.read_bytes()).hexdigest()
            anchors.append(wheel_anchor(fname, digest, md_digest, requires_python(metadata)))
        (pdir / "index.html").write_text(page(f"Links for {project}", anchors))

    root = [f'    <a href="{p}/">{p}</a><br/>' for p in sorted(projects)]
    (out / "simple" / "index.html").write_text(page("Simple index", root))
    (out / "index.html").write_text(landing())
    print(f"indexed {sum(map(len, projects.values()))} wheels across {len(projects)} projects")


if __name__ == "__main__":
    main()
