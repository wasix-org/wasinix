"""Restate a built wheel as the artifact the registry publishes.

The build produces a wheel at its upstream version; publishing gives it the
publication release (PEP 440 local version `+wasix.<rel>`) and, where the entry
is built for fewer interpreters than the index serves, the Requires-Python bound
that says so. Filename, dist-info dir, METADATA and RECORD are kept consistent.

Run per wheel by its own derivation (pkgs/python/wheels/project.nix), so a rel bump
rewrites this cheap output instead of rebuilding the wheel, and the published
bytes have a store path of their own.

Usage: publish-wheel.py <dist dir> <out dir> --rel N
                        [--requires-python BOUND] [--version-suffix S]
                        [--python-tag TAG]
"""

import argparse
import base64
import csv
import hashlib
import io
import re
import sys
import zipfile
from pathlib import Path


def record_hash(data: bytes) -> str:
    # RECORD hash spelling (PEP 376/427): urlsafe base64, no padding
    return "sha256=" + base64.urlsafe_b64encode(
        hashlib.sha256(data).digest()
    ).decode().rstrip("=")


def bump_metadata_version(metadata: bytes, version: str, new_version: str) -> bytes:
    lines = metadata.split(b"\n")
    for i, line in enumerate(lines):
        if not line.strip():
            break  # end of headers, no Version seen
        key, _, value = line.partition(b":")
        if key.strip().lower() == b"version":
            if value.strip().decode() != version:
                sys.exit(
                    f"METADATA Version {value.strip().decode()!r} != filename version {version!r}"
                )
            lines[i] = f"Version: {new_version}".encode()
            return b"\n".join(lines)
    sys.exit("METADATA has no Version header")


def tags_pin_interpreter(fname: str) -> bool:
    """Whether the wheel's own compatibility tags admit one interpreter already.

    An abi3 wheel loads on every later CPython and a pyN tag on any of them, so
    only an exact cp/pp tag makes a Requires-Python bound redundant.
    """
    parts = fname[: -len(".whl")].split("-")
    pytags, abi = parts[-3].split("."), parts[-2]
    return abi != "abi3" and len(pytags) == 1 and pytags[0].startswith(("cp", "pp"))


def set_requires_python(metadata: bytes, bound: str) -> bytes:
    """Replace Requires-Python with the interpreters the wheel is served for.

    A py3-none-any wheel carries no interpreter tag, so this bound is all that
    keeps a resolver on another interpreter from selecting it. It supersedes the
    upstream floor rather than intersecting it: the wheel exists because it
    built on an interpreter named here, so this is the stronger constraint.
    """
    header = f"Requires-Python: {bound}".encode()
    lines = metadata.split(b"\n")
    for i, line in enumerate(lines):
        if not line.strip():
            lines.insert(i, header)  # end of headers, none present
            return b"\n".join(lines)
        key, _, _ = line.partition(b":")
        if key.strip().lower() == b"requires-python":
            lines[i] = header
            return b"\n".join(lines)
    sys.exit("METADATA has no header block")


def set_wheel_tag(wheel: bytes, tag: str) -> bytes:
    """Restate the WHEEL Tag: lines as the single tag the filename now carries."""
    lines = [l for l in wheel.split(b"\n") if not l.lower().startswith(b"tag:")]
    end = next(i for i, l in enumerate(lines) if not l.strip())
    lines.insert(end, f"Tag: {tag}".encode())
    return b"\n".join(lines)


def rewrite_wheel(
    src: Path,
    dest_dir: Path,
    rel: int,
    suffix: str | None = None,
    requires_python: str | None = None,
    python_tag: str | None = None,
) -> Path:
    """Copy the wheel with +wasix.<rel>[.<suffix>] appended to its version.

    The suffix (pr123.abc1234) marks PR-preview wheels: a longer local version
    with an equal prefix sorts higher, so pip prefers them over the published
    wheel when the preview index is used via --extra-index-url.
    """
    name, version, rest = src.name.split("-", 2)
    if "+" in version:
        sys.exit(f"{src.name}: already carries a local version")
    if python_tag:
        _, abi, platform = rest[: -len(".whl")].split("-")
        if (abi, platform) != ("none", "any"):
            sys.exit(
                f"{src.name}: only a none-any wheel can be retagged, not {abi}-{platform}"
            )
        rest = f"{python_tag}-none-any.whl"
    new_version = f"{version}+wasix.{rel}" + (f".{suffix}" if suffix else "")

    with zipfile.ZipFile(src) as zin:
        dist_infos = {
            n.split("/", 1)[0]
            for n in zin.namelist()
            if re.match(r"[^/]+\.dist-info/", n)
        }
        if len(dist_infos) != 1:
            sys.exit(
                f"{src.name}: expected exactly one *.dist-info dir, found {sorted(dist_infos)}"
            )
        old_di = dist_infos.pop()
        if not old_di.endswith(f"-{version}.dist-info"):
            sys.exit(
                f"{src.name}: dist-info dir {old_di!r} does not match filename version {version!r}"
            )
        new_di = (
            old_di.removesuffix(f"-{version}.dist-info") + f"-{new_version}.dist-info"
        )
        rename = lambda n: (
            new_di + n.removeprefix(old_di) if n.startswith(f"{old_di}/") else n
        )

        entries = [
            (rename(i.filename), i, zin.read(i.filename)) for i in zin.infolist()
        ]

    files = {n: data for n, _, data in entries}
    rewritten = {f"{new_di}/METADATA"}
    files[f"{new_di}/METADATA"] = bump_metadata_version(
        files[f"{new_di}/METADATA"], version, new_version
    )
    if requires_python and not tags_pin_interpreter(src.name):
        files[f"{new_di}/METADATA"] = set_requires_python(
            files[f"{new_di}/METADATA"], requires_python
        )
    if python_tag:
        files[f"{new_di}/WHEEL"] = set_wheel_tag(
            files[f"{new_di}/WHEEL"], rest[: -len(".whl")]
        )
        rewritten.add(f"{new_di}/WHEEL")

    # RECORD: renamed paths, plus refreshed hash/size for what was rewritten
    rows = list(csv.reader(io.StringIO(files[f"{new_di}/RECORD"].decode())))
    for row in rows:
        row[0] = rename(row[0])
        if row[0] in rewritten:
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


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("dist", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--rel", type=int, required=True)
    ap.add_argument("--requires-python")
    ap.add_argument(
        "--python-tag",
        help="retag a none-any wheel for one interpreter (cp313), so the two "
        "builds of an interpreter-specific package get distinct filenames",
    )
    ap.add_argument(
        "--version-suffix",
        help="extra local-version segments (pr123.abc1234) for PR-preview wheels",
    )
    args = ap.parse_args()

    wheels = sorted(args.dist.glob("*.whl"))
    if not wheels:
        sys.exit(f"no .whl in {args.dist}")
    args.out.mkdir(parents=True, exist_ok=True)
    for whl in wheels:
        moved = rewrite_wheel(
            whl,
            args.out,
            args.rel,
            args.version_suffix,
            args.requires_python,
            args.python_tag,
        )
        print(moved.name)


if __name__ == "__main__":
    main()
