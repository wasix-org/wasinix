"""Generate a static PEP 503 "simple" package index from built wheels.

Called by default.nix as: make-index.py <dists.json> <out>, where dists.json is
[{"name", "version", "published" = store path with the published .whl}, ...].

The wheels arrive already carrying their publication release and interpreter
bound; each is produced by its own derivation (publish-wheel.py), so this only
indexes what it is given.

Emits, per PEP 503 (+ PEP 629 version meta, PEP 658/714 metadata files):
  <out>/simple/index.html               project list, what PyPI cannot supply
  <out>/simple/<project>/index.html     file list with #sha256= anchors
  <out>/simple/<project>/<wheel>        the wheel itself (relative hrefs)
  <out>/simple/<project>/<wheel>.metadata   its core metadata, for resolvers
  <out>/packages.json                   flat wheel list, for wasmer-compat
  <out>/all/simple/...                  the same listing over every wheel here
"""

import argparse
import hashlib
import html
import json
import re
import sys
import zipfile
from pathlib import Path
from urllib.parse import quote


def normalize(name: str) -> str:
    """PEP 503 project-name normalization."""
    return re.sub(r"[-_.]+", "-", name).lower()


def wheel_metadata(whl: Path) -> bytes:
    with zipfile.ZipFile(whl) as zf:
        names = [
            n for n in zf.namelist() if re.fullmatch(r"[^/]+\.dist-info/METADATA", n)
        ]
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


def _wheel_attrs(md_digest: str, rp: str | None) -> str:
    attrs = ""
    if rp:
        attrs += f' data-requires-python="{html.escape(rp, quote=True)}"'
    # both attribute spellings: data-core-metadata (PEP 714) with the
    # data-dist-info-metadata (PEP 658) fallback for older resolvers.
    attrs += (
        f' data-core-metadata="sha256={md_digest}"'
        f' data-dist-info-metadata="sha256={md_digest}"'
    )
    return attrs


# {name}-{version}-{python}-{abi}-{platform}.whl; version carries +wasix.N and,
# being PEP 440, never contains a hyphen, so a plain split is safe.
def _parse_wheel(fname: str) -> tuple[str, str]:
    parts = fname[: -len(".whl")].split("-")
    return parts[1], parts[-3]  # version, python tag


def is_native(fname: str) -> bool:
    """Whether the wheel is built for a platform rather than being pure python."""
    return fname[: -len(".whl")].rsplit("-", 1)[-1] != "any"


def _ver_key(ver: str) -> tuple[int, ...]:
    return tuple(int(n) for n in re.findall(r"\d+", ver))


# cp313 -> "CPython 3.13", pp310 -> "PyPy 3.10", py3 -> "Python 3".
def _py_label(tag: str) -> str:
    m = re.fullmatch(r"(cp|pp)(\d)(\d+)", tag)
    if m:
        impl = {"cp": "CPython", "pp": "PyPy"}[m.group(1)]
        return f"{impl} {m.group(2)}.{m.group(3)}"
    if m := re.fullmatch(r"py(\d+)", tag):
        return f"Python {m.group(1)}"
    return tag


def _fmt_size(n: int | None) -> str:
    if not n:
        return ""
    size = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024


def _sz(size: int | None) -> str:
    s = _fmt_size(size)
    return f' <span class="sz">{s}</span>' if s else ""


# wasix.org's brand favicon (light + dark), embedded so pages stay
# self-contained; the dark variant swaps in under a dark browser theme.
_FAVICON = '<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxNDk0IiBoZWlnaHQ9IjE0OTQiIGZpbGw9Im5vbmUiIHZpZXdCb3g9IjAgMCAxNDk0IDE0OTQiPgogIDxwYXRoIGZpbGw9IiM5MzkzOTMiIGQ9Ik0xMTU3IDc4My45OTZIMzc3djE2MWg3ODB2LTE2MVoiLz4KICA8cGF0aCBmaWxsPSIjZmZmIiBzdHJva2U9IiMwMDAiIHN0cm9rZS13aWR0aD0iNCIgZD0ibTIxNy4yNjggMTA1MS45NC0xLjczMiAxIDEuNzMyIDEgNTMwLjAwNyAzMDYgMS43MzIgMSAxLjczMi0xTDEyODAuNjUgMTA1NGwxLjczLTEtMS43My0xLTUzMC4wMDgtMzA2LTEuNzMyLTEtMS43MzIgMS01MjkuOTEgMzA1Ljk0WiIvPgogIDxwYXRoIGZpbGw9IiMwMDAiIGQ9Im01NDIuOTk5IDg2NS4wMzEtMTIyLjA4NyA3MC40ODcgNTMwLjAwNyAzMDYuMDAyIDEyMi4wOTEtNzAuNDktNTMwLjAxMS0zMDUuOTk5WiIvPgogIDxwYXRoIGZpbGw9IiM5MzkzOTMiIGQ9Im0xMDczLjQgOTM1LjMwMS0xMjIuMTA1LTcwLjVMNDIwLjk0OSAxMTcxbDEyMi4xMSA3MC41TDEwNzMuNCA5MzUuMzAxWiIvPgogIDxwYXRoIGZpbGw9IiNmZmYiIGZpbGwtcnVsZT0iZXZlbm9kZCIgc3Ryb2tlPSIjMDAwIiBzdHJva2Utd2lkdGg9IjQiIGQ9Ik05NTEuMzgyIDg2NCA3NDcgNzQ2VjEzNGw1MzAuMDEgMzA2djYxMmwtMjA0LjA5LTExNy44M3YtMy4zYzAtMzguNzUtMjcuMi04NS44NzUtNjAuNzctMTA1LjI1NS0zMy41NTctMTkuMzc1LTYwLjc2OC0zLjY3NS02MC43NjggMzUuMDg1djMuM1oiIGNsaXAtcnVsZT0iZXZlbm9kZCIvPgogIDxwYXRoIGZpbGw9IiMwMDAiIGZpbGwtcnVsZT0iZXZlbm9kZCIgZD0iTTEwNDUuNjcgNTU3LjkxNmMtMjMuOTYtMTMuMzk1LTM1Ljk5LTIwLjI1NS0zNi4wOC0yMC41ODEtNC4xLTE1LTExLjMwMi0zMC4yOTgtMjQuMjk0LTM3Ljc5OS0xMi4zNjctNy4xNC0yMy4wMzctMi45NC0yMy4wMzcgMTEuOSAwIDQyLjg0IDg4Ljc1MSA2Ni4wOCA4OC43NTEgMTQ3LjI4IDAgMjYuNi0xNy40NiA1Ni4yOC02NC4wMTcgMjkuNC0zNS44ODgtMjAuNzItNjEuODM0LTU1Ljg2LTY3LjY1NC0xMDEuNzhsMzkuMjM3IDIyLjUyOGMuMDg5LjM4Ny4xODEuNzczLjI3NSAxLjE1OCA0LjE1NiAxNy4wNzIgMTIuNDE3IDMyLjA1NiAyNy45IDQwLjk5NCAxNC43ODkgOC41NCAyNy4xNTkgNi43MiAyNy4xNTktMTIuMDQgMC00My42OC04OC43NTEtNjkuNzItODguNzUxLTE0My45MiAwLTM5LjIgMjguNjEzLTUwLjY4IDYxLjM0OS0zMS43OCAzMi4wMTIgMTguNDggNTYuMDEyIDU2LjE0IDU5LjE2MiA5NC42NFptNTguNzQgMTk0LjYzLTM3LjgzLTIxLjg0di0yMTcuODRsMzcuODMgMjEuODR2MjE3Ljg0WiIgY2xpcC1ydWxlPSJldmVub2RkIi8+CiAgPHBhdGggZmlsbD0iI2ZmZiIgZmlsbC1ydWxlPSJldmVub2RkIiBzdHJva2U9IiMwMDAiIHN0cm9rZS13aWR0aD0iNCIgZD0ibTQyMy41MTggOTMzLjk5Ni0uMDExLTMuM2MtLjEzNi0zOC43NTkgMjYuOTY1LTg1Ljg3OSA2MC41MjQtMTA1LjI1NCAzMy41NjctMTkuMzggNjAuODc4LTMuNjY1IDYxLjAxNCAzNS4wODRsLjAxMSAzLjMgMjA0LjA4OC0xMTcuODNMNzQ3LjAwNyAxMzQgMjE3IDQ0MGwyLjEzNiA2MTIgMjA0LjM4Mi0xMTguMDA0WiIgY2xpcC1ydWxlPSJldmVub2RkIi8+CiAgPHBhdGggZmlsbD0iIzAwMCIgZD0ibTMwMi41NjIgNTg4Ljk5OSAzNS4xMjYtMjAuMjggMjQuNDk1IDEzMy42MjQuNDMzLS4yNSAyOC4zMDYtMTY0LjEwOSAzMi44NTctMTguOTcgMjYuNTU0IDEzNC4yNDkuNTExLS4yOTUgMjYuODExLTE2NS4wNTkgMzQuNDUtMTkuODktNDQuMDA4IDI0Mi41MzQtMzQuODU4IDIwLjEyNS0yNi4zMzEtMTMyLjU2NC0uNjc1LjM5LTI3LjEyMSAxNjMuNDI0LTM1LjUwNyAyMC41LTQxLjA0My0xOTMuNDI5Wm0yNDkuMTQ2LTE0My44NDUgNTUuMzc0LTMxLjk3IDU1Ljc0OSAxODQuOTM5LTM2LjIzNCAyMC45Mi0xMi4xMjktNDEuMzE1LTYzLjA4MSAzNi40Mi05LjA2MyA1My41NS0zNS4yOTEgMjAuMzc1IDQ0LjY3NS0yNDIuOTE5Wm0yMS4yNjYgNDEuMjQtMTUuMDQzIDg4LjM0NCA0Ny42ODQtMjcuNTMtMTcuODY3LTY5LjM0NC0xNC43NzQgOC41M1ptMzc3Ljk4MyAzNzguNjAyIDEyMi4xMTMgNzAuNUw1NDMuMDU5IDEyNDEuNWwtMTIyLjExLTcwLjUgNTMwLjAwOC0zMDYuMDA0WiIvPgogIDxwYXRoIGZpbGw9IiMxODE4MTgiIGZpbGwtcnVsZT0iZXZlbm9kZCIgZD0ibTk1MSA4NjQuNjg1IDUwLjEyIDI5LjUgNzEuNDIgNDAuNjd2LTMuM2MwLTM4Ljc1LTI3LjItODUuODc1LTYwLjc3LTEwNS4yNTUtMzMuNTU5LTE5LjM3NS02MC43Ny0zLjY3NS02MC43NyAzNS4wODV2My4zWiIgY2xpcC1ydWxlPSJldmVub2RkIi8+CiAgPHBhdGggZmlsbD0iIzEzMTMxMyIgZmlsbC1ydWxlPSJldmVub2RkIiBkPSJtNTQ0LjUzOCA4NjMuNjg1LTUwLjExOCAyOS41LTcxLjQyIDQwLjY3di0zLjNjMC0zOC43NSAyNy4yMDItODUuODc1IDYwLjc2OS0xMDUuMjU1IDMzLjU1OS0xOS4zNzUgNjAuNzY5LTMuNjc1IDYwLjc2OSAzNS4wODV2My4zWiIgY2xpcC1ydWxlPSJldmVub2RkIi8+Cjwvc3ZnPgo="/>\n    <link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxNDk0IiBoZWlnaHQ9IjE0OTQiIGZpbGw9Im5vbmUiIHZpZXdCb3g9IjAgMCAxNDk0IDE0OTQiPgogIDxwYXRoIGZpbGw9IiM5MzkzOTMiIGQ9Ik0xMTU4IDc4My45OTZIMzc4djE2MWg3ODB2LTE2MVoiLz4KICA8cGF0aCBmaWxsPSIjMDAwIiBzdHJva2U9IiNmZmYiIHN0cm9rZS13aWR0aD0iNCIgZD0ibTIxOC4yNjggMTA1MS45NC0xLjczMiAxIDEuNzMyIDEgNTMwLjAwNyAzMDYgMS43MzIgMSAxLjczMi0xTDEyODEuNjUgMTA1NGwxLjczLTEtMS43My0xLTUzMC4wMDgtMzA2LTEuNzMyLTEtMS43MzIgMS01MjkuOTEgMzA1Ljk0WiIvPgogIDxwYXRoIGZpbGw9IiNmZmYiIGQ9Im01NDMuOTk5IDg2NS4wMzEtMTIyLjA4NyA3MC40ODcgNTMwLjAwNyAzMDYuMDAyIDEyMi4wOTEtNzAuNDktNTMwLjAxMS0zMDUuOTk5WiIvPgogIDxwYXRoIGZpbGw9IiM5MzkzOTMiIGQ9Im0xMDc0LjQgOTM1LjMwMS0xMjIuMTA1LTcwLjVMNDIxLjk0OSAxMTcxbDEyMi4xMSA3MC41TDEwNzQuNCA5MzUuMzAxWiIvPgogIDxwYXRoIGZpbGw9IiMwMDAiIGZpbGwtcnVsZT0iZXZlbm9kZCIgc3Ryb2tlPSIjZmZmIiBzdHJva2Utd2lkdGg9IjQiIGQ9Ik05NTIuMzgyIDg2NCA3NDggNzQ2VjEzNGw1MzAuMDEgMzA2djYxMmwtMjA0LjA5LTExNy44M3YtMy4zYzAtMzguNzUtMjcuMi04NS44NzUtNjAuNzctMTA1LjI1NS0zMy41NTctMTkuMzc1LTYwLjc2OC0zLjY3NS02MC43NjggMzUuMDg1djMuM1oiIGNsaXAtcnVsZT0iZXZlbm9kZCIvPgogIDxwYXRoIGZpbGw9IiNmZmYiIGZpbGwtcnVsZT0iZXZlbm9kZCIgZD0iTTEwNDYuNjcgNTU3LjkxNmMtMjMuOTYtMTMuMzk1LTM1Ljk5LTIwLjI1NS0zNi4wOC0yMC41ODEtNC4xLTE1LTExLjMwMi0zMC4yOTgtMjQuMjk0LTM3Ljc5OS0xMi4zNjctNy4xNC0yMy4wMzctMi45NC0yMy4wMzcgMTEuOSAwIDQyLjg0IDg4Ljc1MSA2Ni4wOCA4OC43NTEgMTQ3LjI4IDAgMjYuNi0xNy40NiA1Ni4yOC02NC4wMTcgMjkuNC0zNS44ODgtMjAuNzItNjEuODM0LTU1Ljg2LTY3LjY1NC0xMDEuNzhsMzkuMjM3IDIyLjUyOGMuMDg5LjM4Ny4xODEuNzczLjI3NSAxLjE1OCA0LjE1NiAxNy4wNzIgMTIuNDE3IDMyLjA1NiAyNy45IDQwLjk5NCAxNC43ODkgOC41NCAyNy4xNTkgNi43MiAyNy4xNTktMTIuMDQgMC00My42OC04OC43NTEtNjkuNzItODguNzUxLTE0My45MiAwLTM5LjIgMjguNjEzLTUwLjY4IDYxLjM0OS0zMS43OCAzMi4wMTIgMTguNDggNTYuMDEyIDU2LjE0IDU5LjE2MiA5NC42NFptNTguNzQgMTk0LjYzLTM3LjgzLTIxLjg0di0yMTcuODRsMzcuODMgMjEuODR2MjE3Ljg0WiIgY2xpcC1ydWxlPSJldmVub2RkIi8+CiAgPHBhdGggZmlsbD0iIzAwMCIgZmlsbC1ydWxlPSJldmVub2RkIiBzdHJva2U9IiNmZmYiIHN0cm9rZS13aWR0aD0iNCIgZD0ibTQyNC41MTggOTMzLjk5Ni0uMDExLTMuM2MtLjEzNi0zOC43NTkgMjYuOTY1LTg1Ljg3OSA2MC41MjQtMTA1LjI1NCAzMy41NjctMTkuMzggNjAuODc4LTMuNjY1IDYxLjAxNCAzNS4wODRsLjAxMSAzLjMgMjA0LjA4OC0xMTcuODNMNzQ4LjAwNyAxMzQgMjE4IDQ0MGwyLjEzNiA2MTIgMjA0LjM4Mi0xMTguMDA0WiIgY2xpcC1ydWxlPSJldmVub2RkIi8+CiAgPHBhdGggZmlsbD0iI2ZmZiIgZD0ibTMwMy41NjIgNTg4Ljk5OSAzNS4xMjYtMjAuMjggMjQuNDk1IDEzMy42MjQuNDMzLS4yNSAyOC4zMDYtMTY0LjEwOSAzMi44NTctMTguOTcgMjYuNTU0IDEzNC4yNDkuNTExLS4yOTUgMjYuODExLTE2NS4wNTkgMzQuNDUtMTkuODktNDQuMDA4IDI0Mi41MzQtMzQuODU4IDIwLjEyNS0yNi4zMzEtMTMyLjU2NC0uNjc1LjM5LTI3LjEyMSAxNjMuNDI0LTM1LjUwNyAyMC41LTQxLjA0My0xOTMuNDI5Wm0yNDkuMTQ2LTE0My44NDUgNTUuMzc0LTMxLjk3IDU1Ljc0OSAxODQuOTM5LTM2LjIzNCAyMC45Mi0xMi4xMjktNDEuMzE1LTYzLjA4MSAzNi40Mi05LjA2MyA1My41NS0zNS4yOTEgMjAuMzc1IDQ0LjY3NS0yNDIuOTE5Wm0yMS4yNjYgNDEuMjQtMTUuMDQzIDg4LjM0NCA0Ny42ODQtMjcuNTMtMTcuODY3LTY5LjM0NC0xNC43NzQgOC41M1ptMzc3Ljk4MyAzNzguNjAyIDEyMi4xMTMgNzAuNUw1NDQuMDU5IDEyNDEuNWwtMTIyLjExLTcwLjUgNTMwLjAwOC0zMDYuMDA0WiIvPgogIDxwYXRoIGZpbGw9IiNmZmYiIGZpbGwtcnVsZT0iZXZlbm9kZCIgZD0ibTk1MiA4NjQuNjg1IDUwLjEyIDI5LjUgNzEuNDIgNDAuNjd2LTMuM2MwLTM4Ljc1LTI3LjItODUuODc1LTYwLjc3LTEwNS4yNTUtMzMuNTU5LTE5LjM3NS02MC43Ny0zLjY3NS02MC43NyAzNS4wODV2My4zWm0tNDA2LjQ2Mi0xLTUwLjExOCAyOS41LTcxLjQyIDQwLjY3di0zLjNjMC0zOC43NSAyNy4yMDItODUuODc1IDYwLjc2OS0xMDUuMjU1IDMzLjU1OS0xOS4zNzUgNjAuNzY5LTMuNjc1IDYwLjc2OSAzNS4wODV2My4zWiIgY2xpcC1ydWxlPSJldmVub2RkIi8+Cjwvc3ZnPgo=" media="(prefers-color-scheme: dark)"/>'

_CSS = """
      :root {
        color-scheme: light dark;
        --bg: #fbfbfd; --fg: #1c1c24; --muted: #70707e;
        --accent: #5b54c9; --code-bg: #f1f1f6; --border: #e7e7ef;
      }
      @media (prefers-color-scheme: dark) {
        :root {
          --bg: #16161b; --fg: #e7e7ef; --muted: #9a9aa8;
          --accent: #ab9dff; --code-bg: #22222b; --border: #2b2b35;
        }
      }
      * { box-sizing: border-box; }
      body {
        background: var(--bg); color: var(--fg);
        font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
        max-width: 44rem; margin: 0 auto; padding: 3.5rem 1.25rem 5rem;
        line-height: 1.65;
      }
      h1 { font-size: 1.55rem; letter-spacing: -0.01em; margin: 0 0 .4rem; }
      .lede { color: var(--muted); margin: 0; }
      h2 {
        font-size: .72rem; text-transform: uppercase; letter-spacing: .09em;
        color: var(--muted); margin: 2.75rem 0 .85rem;
        padding-bottom: .4rem; border-bottom: 1px solid var(--border);
      }
      a { color: var(--accent); text-decoration: none; }
      a:hover { text-decoration: underline; }
      code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      pre {
        background: var(--code-bg); border: 1px solid var(--border);
        border-radius: .55rem; padding: .85rem 1.05rem; overflow-x: auto;
        margin: 0; font-size: .88rem;
      }
      ul.pkgs {
        list-style: none; padding: 0; margin: 0;
        display: grid; grid-template-columns: repeat(auto-fill, minmax(9rem, 1fr));
        gap: .05rem .9rem;
      }
      ul.pkgs a {
        display: block; margin: 0 -.4rem; padding: .2rem .4rem; border-radius: .35rem;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .85rem;
      }
      ul.pkgs a:hover { background: var(--code-bg); text-decoration: none; }
      ul.pkgs li[hidden] { display: none; }
      .filter {
        width: 100%; font: inherit; font-size: .9rem; margin: 0 0 .9rem;
        padding: .5rem .7rem; background: var(--bg); color: var(--fg);
        border: 1px solid var(--border); border-radius: .5rem;
      }
      .filter::placeholder { color: var(--muted); }
      .filter:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; border-color: var(--accent); }
      .empty { color: var(--muted); font-size: .9rem; margin: .3rem 0 0; }
      .crumb { margin: 0 0 1.4rem; font-size: .85rem; }
      .rel { margin: 1.5rem 0; }
      .rel .v {
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .95rem;
      }
      ul.whls {
        display: flex; flex-wrap: wrap; gap: .4rem;
        margin: .5rem 0 0; padding: 0; list-style: none;
      }
      ul.whls a {
        display: inline-block; padding: .25rem .6rem; font-size: .8rem;
        border: 1px solid var(--border); border-radius: .4rem; background: var(--code-bg);
      }
      ul.whls a:hover { border-color: var(--accent); text-decoration: none; }
      ul.whls .sz { margin-left: .35rem; color: var(--muted); }
      .rel .rev { margin-left: .55rem; font-size: .8rem; color: var(--muted); }
      .rel .rev:hover { color: var(--accent); }
      .rel .date { margin-left: .55rem; font-size: .8rem; color: var(--muted); }
      .src { margin: .55rem 0 0; font-size: .8rem; color: var(--muted); }
      .src a:hover { color: var(--accent); }
      .repro { display: flex; gap: .4rem; margin: .55rem 0 0; }
      .repro code {
        flex: 1; min-width: 0; overflow-x: auto; white-space: nowrap;
        background: var(--code-bg); border: 1px solid var(--border);
        border-radius: .4rem; padding: .4rem .6rem; font-size: .8rem;
      }
      .copy {
        flex: none; font: inherit; font-size: .78rem; cursor: pointer; color: var(--fg);
        background: var(--code-bg); border: 1px solid var(--border);
        border-radius: .4rem; padding: .4rem .7rem;
      }
      .copy:hover { border-color: var(--accent); }
      .copy.copied { color: var(--accent); border-color: var(--accent); }
      .note { color: var(--muted); font-size: .85rem; margin-top: 3rem; }
"""


# Inline, as a plain string so its braces aren't f-string substitutions: fill
# the pip index URL from the page's own location, and live-filter the package
# grid (graceful with JS off -- the input is inert and every package shows).
_SCRIPT = """
      document.getElementById("url").textContent = new URL("simple/", location.href).href;
      (function () {
        var q = document.getElementById("filter");
        var items = Array.prototype.slice.call(document.querySelectorAll("ul.pkgs li"));
        var head = document.getElementById("pkgs-h");
        var empty = document.getElementById("empty");
        var total = items.length;
        q.addEventListener("input", function () {
          var v = q.value.trim().toLowerCase();
          var n = 0;
          items.forEach(function (li) {
            var match = li.textContent.toLowerCase().indexOf(v) !== -1;
            li.hidden = !match;
            if (match) n++;
          });
          head.textContent = v
            ? n + " of " + total + " packages"
            : total + (total === 1 ? " package" : " packages");
          empty.hidden = n !== 0;
        });
      })();
"""


# Project page: fill the pip index URL from the page's location, and wire the
# per-release "copy reproduce command" buttons (no-op with JS off).
_PROJECT_SCRIPT = """
      document.getElementById("url").textContent = new URL("../", location.href).href;
      document.querySelectorAll(".copy").forEach(function (b) {
        b.addEventListener("click", function () {
          navigator.clipboard.writeText(b.previousElementSibling.textContent).then(function () {
            b.textContent = "Copied";
            b.classList.add("copied");
            setTimeout(function () {
              b.textContent = "Copy";
              b.classList.remove("copied");
            }, 1200);
          });
        });
      });
"""


def landing(projects) -> str:
    """Human-facing entry page (pip only ever sees simple/)."""
    names = sorted(projects)
    items = "\n".join(
        f'      <li><a href="simple/{quote(p)}/">{html.escape(p)}</a></li>'
        for p in names
    )
    n = len(names)
    return f"""<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    {_FAVICON}
    <title>WASIX Python package index</title>
    <style>{_CSS}    </style>
  </head>
  <body>
    <h1>WASIX Python package index</h1>
    <p class="lede">Python wheels cross-compiled to WASIX (<code>wasm32-wasix</code>):
      prebuilt native extensions that run under <a href="https://wasmer.io/">Wasmer</a>,
      so <code>pip install</code> works where it otherwise could not.</p>

    <h2>Install</h2>
    <pre><code>pip install --index-url <span id="url">&lt;this page&gt;/simple/</span> &lt;package&gt;</code></pre>

    <h2 id="pkgs-h">{n} package{"" if n == 1 else "s"}</h2>
    <input class="filter" id="filter" type="search" placeholder="Filter packages&hellip;"
      aria-label="Filter packages" autocomplete="off" spellcheck="false"/>
    <ul class="pkgs">
{items}
    </ul>
    <p class="empty" id="empty" hidden>No packages match.</p>

    <p class="note">Each wheel is republished as <code>&lt;version&gt;+wasix.&lt;N&gt;</code>
      (the Nth WASIX build of that version). Raw index: <a href="simple/">simple/</a>.</p>

    <script>{_SCRIPT}    </script>
  </body>
</html>
"""


def page(title: str, anchors: list[str]) -> str:
    lines = "\n".join(anchors)
    return f"""<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    {_FAVICON}
    <meta name="pypi:repository-version" content="1.1"/>
    <title>{html.escape(title)}</title>
    <style>{_CSS}    </style>
  </head>
  <body>
    <h1>{html.escape(title)}</h1>
{lines}
  </body>
</html>
"""


_REPO = "https://github.com/wasix-org/wasinix"


def project_page(project: str, files: list[tuple], href_prefix: str = "") -> str:
    """Human-friendly file list for one project, grouped by version.

    href_prefix points the anchors at another directory, so the native view
    lists the wheels simple/ already holds rather than copying them.

    files: (filename, sha256, metadata_sha256, requires_python, wasinix_rev,
    attr, size, published, source). Resolvers read only the <a> href and data-*
    attributes; the surrounding markup is ignored, so this stays PEP 503
    compliant. rev/attr/published/source are None for the pre-publish nix
    build, which just drops the provenance line.
    """
    by_ver: dict[str, list] = {}
    meta: dict[str, tuple] = {}
    for fname, digest, md_digest, rp, rev, attr, size, published, source in files:
        ver, py = _parse_wheel(fname)
        by_ver.setdefault(ver, []).append((fname, digest, md_digest, rp, py, size))
        # a release's wheels share one build
        meta[ver] = (rev, attr, published, source)
    rels = []
    for ver in sorted(by_ver, key=_ver_key, reverse=True):
        chips = "\n".join(
            f'        <li><a href="{href_prefix}{quote(fname)}#sha256={digest}"'
            f'{_wheel_attrs(md_digest, rp)} title="{html.escape(fname, quote=True)}">'
            f"{html.escape(_py_label(py))}{_sz(size)}</a></li>"
            for fname, digest, md_digest, rp, py, size in sorted(by_ver[ver])
        )
        rev, attr, published, source = meta[ver]
        extras = repro = ""
        if rev and attr:
            r = html.escape(rev, quote=True)
            extras += (
                f' <a class="rev" href="{_REPO}/commit/{r}"'
                f' title="wasinix commit {r}">{html.escape(rev[:7])}</a>'
            )
            cmd = f"nix build 'github:wasix-org/wasinix/{rev}#{attr}'"
            src = ""
            if source:
                sfile, _, sline = source.rpartition(":")
                sref = f"{_REPO}/blob/{r}/{quote(sfile)}#L{html.escape(sline)}"
                src = (
                    f'\n      <div class="src">built from <a href="{sref}">'
                    f"{html.escape(sfile)}:{html.escape(sline)}</a></div>"
                )
            repro = src + (
                f'\n      <div class="repro"><code>{html.escape(cmd)}</code>'
                f'<button class="copy" type="button" aria-label="Copy reproduce command">Copy</button></div>'
            )
        if published:
            extras += f' <span class="date">{html.escape(published)}</span>'
        rels.append(
            f'    <div class="rel">\n'
            f'      <div class="v">{html.escape(ver)}{extras}</div>\n'
            f'      <ul class="whls">\n{chips}\n      </ul>{repro}\n'
            f"    </div>"
        )
    body = "\n".join(rels)
    return f"""<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1"/>
    {_FAVICON}
    <meta name="pypi:repository-version" content="1.1"/>
    <title>{html.escape(project)} &middot; WASIX Python index</title>
    <style>{_CSS}    </style>
  </head>
  <body>
    <p class="crumb"><a href="../../">&larr; all packages</a></p>
    <h1>{html.escape(project)}</h1>
    <pre><code>pip install --index-url <span id="url">&lt;this index&gt;/</span> {html.escape(project)}</code></pre>
{body}
    <script>{_PROJECT_SCRIPT}    </script>
  </body>
</html>
"""


def write_packages_json(dest: Path, served) -> None:
    """Flat wheel list, one JSON object per line, read by wasmer-compat to decide
    which projects the index covers. It drops any line it cannot parse, so an
    entry that loses its `filename` key goes silently uncounted."""
    dest.write_text(
        "".join(
            json.dumps({"filename": fname, "hash": f"sha256={digest}"}) + "\n"
            for fname, digest in sorted(served)
        )
    )


def is_primary(files: list[tuple]) -> bool:
    """Whether PyPI cannot correctly supply this project.

    Either a wheel is platform-tagged, so PyPI has nothing that loads under
    wasix, or the package has an overlay entry here, so our build differs from
    upstream's and taking PyPI's copy would silently drop that difference.
    """
    return any(
        is_native(fname) or source
        for fname, _digest, _md, _rp, _rev, _attr, _size, _published, source in files
    )


def write_views(out: Path, pages: dict[str, list[tuple]]) -> dict:
    """Write both PEP 503 listings over the wheels under simple/<project>/.

    simple/ lists what PyPI cannot supply, so a resolver takes it as the
    priority index beside PyPI and gets our wheel for exactly those, leaving
    every other dependency to PyPI at the version the consuming project asks
    for. all/simple/ lists everything published, for installing the closure
    from here alone (docs/registry.md). Both point at one copy of each wheel.
    """
    primary = {project: files for project, files in pages.items() if is_primary(files)}
    for project, files in sorted(primary.items()):
        pdir = out / "simple" / project
        pdir.mkdir(parents=True, exist_ok=True)
        (pdir / "index.html").write_text(project_page(project, files))
    proot = [f'    <a href="{p}/">{p}</a><br/>' for p in sorted(primary)]
    (out / "simple" / "index.html").write_text(page("Simple index", proot))

    for project, files in sorted(pages.items()):
        adir = out / "all" / "simple" / project
        adir.mkdir(parents=True, exist_ok=True)
        (adir / "index.html").write_text(
            project_page(
                project, files, href_prefix=f"../../../simple/{quote(project)}/"
            )
        )
    aroot = [f'    <a href="{p}/">{p}</a><br/>' for p in sorted(pages)]
    (out / "all" / "simple" / "index.html").write_text(page("Simple index", aroot))
    return primary


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("dists", type=Path)
    ap.add_argument("out", type=Path)
    args = ap.parse_args()
    dists = json.loads(args.dists.read_text())
    out = args.out

    # normalized project name -> {published filename -> its path}
    projects: dict[str, dict[str, Path]] = {}
    # published filename -> {name, attr, drv_path}, folded into each wheel's
    # manifest by publish.py (with the wasinix rev added there).
    provenance: dict[str, dict] = {}
    # Collected rather than fatal on the first, so one run names every entry that
    # needs `publishOnce` instead of one per rebuild.
    conflicts: list[tuple[str, str]] = []
    for entry in dists:
        wheels = sorted(Path(entry["published"]).glob("*.whl"))
        if not wheels:
            sys.exit(f"no .whl published for '{entry['name']}': {entry['published']}")
        for whl in wheels:
            project = normalize(whl.name.split("-", 1)[0])
            prev = projects.setdefault(project, {}).setdefault(whl.name, whl)
            if prev is not whl:
                if prev.read_bytes() != whl.read_bytes():
                    conflicts.append((whl.name, entry["attr"]))
                # `prev` is what the page serves, so its provenance is the one
                # that reproduces these bytes.
                continue
            provenance[whl.name] = {
                "name": entry["name"],
                "rel_key": entry["relKey"],
                "version": entry["version"],
                "attr": entry["attr"],
                "drv_path": entry["drvPath"],
                **({"source": entry["source"]} if entry.get("source") else {}),
            }

    if conflicts:
        listed = "\n".join(
            f"  {name}  ({attr})" for name, attr in sorted(set(conflicts))
        )
        sys.exit(
            "wheels of the same name differ between interpreters, so which one is"
            " served would be arbitrary. Mark the package"
            " `passthru.wasix.interpreterSpecific` to publish each build under its"
            " own tag, or `publishOnce` in wheels.nix to serve one of them:\n"
            f"{listed}"
        )

    served: list[tuple[str, str]] = []
    # project -> the rows its page was built from, reused by the native view
    pages: dict[str, list[tuple]] = {}
    for project, wheels in sorted(projects.items()):
        pdir = out / "simple" / project
        pdir.mkdir(parents=True)
        files = []
        for fname, src in sorted(wheels.items()):
            (pdir / fname).write_bytes(src.read_bytes())
            metadata = wheel_metadata(src)
            (pdir / f"{fname}.metadata").write_bytes(metadata)
            md_digest = hashlib.sha256(metadata).hexdigest()
            digest = hashlib.sha256(src.read_bytes()).hexdigest()
            served.append((fname, digest))
            # rev/attr/published are publish-time facts (publish.py fills them
            # from the manifest); size is intrinsic and source decides which
            # listing the project lands in, so both are known here already.
            files.append(
                (
                    fname,
                    digest,
                    md_digest,
                    requires_python(metadata),
                    None,
                    None,
                    src.stat().st_size,
                    None,
                    provenance[fname].get("source"),
                )
            )
        pages[project] = files

    primary = write_views(out, pages)

    (out / "index.html").write_text(landing(projects))
    (out / "provenance.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n"
    )
    write_packages_json(out / "packages.json", served)
    print(
        f"indexed {sum(map(len, projects.values()))} wheels across {len(projects)} projects"
        f" ({len(primary)} of them served to a resolver beside PyPI)"
    )


if __name__ == "__main__":
    main()
