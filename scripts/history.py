#!/usr/bin/env python3
"""Maintain the registry-history tables (older versions we keep rebuildable).

Two tables, one shape, one writer: wheels in
pkgs/overlay/python-packages/history.json, CLIs (webc) in
pkgs/overlay/packages/history.json. `add <attr>==<version>` resolves the attr
to its set and writes the matching table.

The spec re-points the package's OWN src fetcher at the older version (version
for fetchPypi, tag/rev for fetchFromGitHub, url for a fetchurl release
tarball), hashed the fetcher's way: PyPI sdist digest for fetchPypi, a TOFU
build for an overridable fetcher (github), prefetch for a url.

`variants` is the set-neutral history gate: the build variants an entry is
limited to (a set with a single variant, like CLIs, has none). Wheels are the
only variant set today -- a variant is an interpreter, defaulted from the
release's upstream wheel tags (cp313/cp314, abi3, pure); a release supporting
neither shipped interpreter is refused (--force keeps it, --skip-unsupported
no-ops it for automation), or narrow it with --variants.

--per-major/--per-minor enumerate the source's version index: PyPI for wheels,
github tags for a fetchFromGitHub package (wheels or CLIs); a bare fetchurl
mirror has no index, so those take explicit versions. from-lockfile reads
python lockfiles, so it is wheels-only.

Usage:
  history.py add <attr>==<version> [--variants py313,py314] [--note N] [--project P] [--set S] [--dry-run]
  history.py add <attr> (--per-major | --per-minor) [--since V] [--set S] [--dry-run]
  history.py from-lockfile <path> [--dry-run]   # requirements.txt, uv.lock, poetry.lock
"""

import argparse
import base64
import functools
import json
import os
import re
import subprocess
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

SYSTEM = "x86_64-linux"
INTERPRETERS = ("py313", "py314")
FAKE_HASH = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

REPO = Path(
    subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()
)
WHEEL_HISTORY = REPO / "pkgs/overlay/python-packages/history.json"
CLI_HISTORY = REPO / "pkgs/overlay/packages/history.json"
WHEELS = REPO / "pkgs/overlay/python-packages/wheels.nix"


def run(cmd):
    return subprocess.run(cmd, cwd=REPO, text=True, capture_output=True, check=True)


def normalize(name):
    # PEP 503
    return re.sub(r"[-_.]+", "-", name).lower()


def pypi(url):
    req = urllib.request.Request(url, headers={"User-Agent": "wasinix-history"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def gh(path):
    req = urllib.request.Request(
        f"https://api.github.com/{path}",
        headers={
            "User-Agent": "wasinix-history",
            "Accept": "application/vnd.github+json",
        },
    )
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if tok:  # lifts the 60/hr unauthenticated rate limit
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def github_tags(owner, repo):
    tags, page = [], 1
    while page <= 10:  # cap: 1000 tags is plenty to cover every major
        data = gh(f"repos/{owner}/{repo}/tags?per_page=100&page={page}")
        tags += [t["name"] for t in data]
        if len(data) < 100:
            break
        page += 1
    return tags


def parse_version(v):
    # release-grade versions only; pre/dev/post are never history candidates
    m = re.fullmatch(r"(\d+(?:\.\d+)*)", v)
    return tuple(int(p) for p in m.group(1).split(".")) if m else None


# ── target resolution: an attr belongs to the wheel set or the CLI set ────────


# frozen: hashable, so the nix evals keyed on a Target can be cached
@dataclass(frozen=True)
class Target:
    kind: str  # "wheel" | "cli"
    attr: str  # history.json key (wheel attr, or CLI overlay attr)
    path: str  # flake attr path of the CURRENT package (src_coords/tofu base)
    history: Path
    pypi: bool  # has PyPI metadata (release list, sdist hash, wheel tags)
    variants: tuple | None  # set's build-variant axis (history `variants` gate);
    # None = single variant (no gating). For wheels a variant is an interpreter.


# cached: from-lockfile resolves one name per pin, and each miss is a nix eval
@functools.cache
def wheel_worklist():
    # wheels.nix is pure data; keyed by normalized attr for lockfile matching
    out = run(
        ["nix", "eval", "--json", "--impure", "--expr", f"import {WHEELS}"]
    ).stdout
    return {normalize(e["attr"]): e["attr"] for e in json.loads(out)}


@functools.cache
def cli_map():
    # webc name -> overlay attr, for the current (non-history) shipped CLIs; the
    # history.json / loader key by overlay attr (gitMinimal), the package is
    # eval'd by webc name (git). Resolvable under either name.
    out = run(
        [
            "nix",
            "eval",
            "--json",
            ".#wasmerPackages",
            "--apply",
            "ws: builtins.mapAttrs (webc: p: { overlay = p.overlayName; "
            "history = p.passthru.wasmer.history or false; }) ws",
        ]
    ).stdout
    m = {}
    for webc, info in json.loads(out).items():
        if info["history"]:
            continue
        entry = {"attr": info["overlay"], "webc": webc}
        m[normalize(info["overlay"])] = entry
        m[normalize(webc)] = entry
    return m


def try_resolve(name, set_hint=None):
    # set_hint disambiguates names in both sets (e.g. jq is a wheel binding AND a
    # CLI). None = search both and report ambiguity.
    n = normalize(name)
    a = wheel_worklist().get(n) if set_hint in (None, "wheel") else None
    e = cli_map().get(n) if set_hint in (None, "cli") else None
    if a is not None and e is not None:
        sys.exit(f"{name}: in both the wheel and CLI sets; pass --set wheel|cli")
    if a is not None:
        return Target(
            "wheel", a, f'pythonWheels.py314."{a}"', WHEEL_HISTORY, True, INTERPRETERS
        )
    if e is not None:
        return Target(
            "cli", e["attr"], f'wasmerPackages."{e["webc"]}"', CLI_HISTORY, False, None
        )
    return None


def resolve(name, set_hint=None):
    t = try_resolve(name, set_hint)
    if t is None:
        sys.exit(f"{name}: not a shipped wheel or CLI")
    return t


# ── the package's own fetcher, re-pointed at a history version ─────────────────


@functools.cache
def src_coords(target):
    """Current package's src fetcher fields, to re-point using the SAME fetcher."""
    out = run(
        [
            "nix",
            "eval",
            "--json",
            f".#{target.path}",
            "--apply",
            "p: { version = p.version; tag = p.src.tag or null; "
            "rev = p.src.rev or null; url = p.src.url or null; "
            "owner = p.src.owner or null; repo = p.src.repo or null; "
            "hasOverride = p.src ? override; }",
        ]
    ).stdout
    return json.loads(out)


def list_versions(target, project, coords):
    """Available upstream versions for --per-major/--per-minor, from whatever
    index the source has: PyPI for wheels (also on PyPI even when nixpkgs
    fetches them from github), github tags for a fetchFromGitHub package,
    nothing for a bare fetchurl mirror."""
    if target.pypi:
        return list(pypi(f"https://pypi.org/pypi/{project}/json")["releases"].keys())
    if coords["owner"] and coords["repo"]:
        # the constant part of the current tag/rev around its version, e.g.
        # "v2.5.0" -> "v", "15.2.0" -> ""; used to read a version out of each tag
        field = coords["tag"] or coords["rev"] or ""
        ver = coords["version"]
        prefix = field[: field.index(ver)] if ver in field else ""
        out = []
        for tag in github_tags(coords["owner"], coords["repo"]):
            if prefix and not tag.startswith(prefix):
                continue
            v = tag[len(prefix) :]
            if parse_version(v):
                out.append(v)
        return out
    sys.exit(
        f"{target.attr}: --per-major/--per-minor need a version index; its source "
        "is a bare fetchurl (no tag list), so add versions explicitly"
    )


def nix_attrs(spec):
    return "{ " + " ".join(f'{k} = "{v}";' for k, v in spec.items()) + " }"


def tofu_hash(target, override_args):
    # build the current src re-pointed with override_args + a fake hash; the
    # fixed-output mismatch reports the real one. The fake hash is required: a
    # FOD is keyed by its output hash, so keeping the old one would return the
    # cached old content instead of fetching. Reuses the package's fetcher.
    expr = (
        f'(builtins.getFlake "{REPO}").legacyPackages.{SYSTEM}'
        f".{target.path}.src.override "
        f"({nix_attrs({**override_args, 'hash': FAKE_HASH})})"
    )
    r = subprocess.run(
        ["nix", "build", "--impure", "--no-link", "--expr", expr],
        cwd=REPO,
        text=True,
        capture_output=True,
    )
    m = re.search(r"got:\s*(sha256-\S+)", r.stderr)
    if not m:
        raise SystemExit(
            f"could not TOFU hash for {target.attr}: {r.stderr.strip()[-400:]}"
        )
    return m.group(1)


def substitute_version(field, value, cur, version):
    """Re-point one fetcher field from `cur` to `version`. A no-op substitution
    means the current version is not spelled in the field (a bare commit rev, or
    a url whose name drops the patch suffix like bash's 5.3p9 -> bash-5.3.tar.gz):
    that would silently pin the CURRENT source under an older version's key, so
    refuse instead."""
    out = value.replace(cur, version)
    if out == value:
        raise ValueError(
            f'cannot re-point src.{field} "{value}" from {cur} to {version}: '
            f"the current version does not appear in it, so the older release "
            f"has to be added by hand"
        )
    return out


def fetch_spec(target, version, coords, files):
    """Spec that re-points the package's own fetcher at <version>: substitute the
    version into the fetcher's version field, hash it the fetcher's way."""
    cur = coords["version"]
    for field in ("tag", "rev"):
        if coords[field] is not None:
            args = {field: substitute_version(field, coords[field], cur, version)}
            return {**args, "hash": tofu_hash(target, args)}
    if coords["hasOverride"]:  # fetchPypi: version -> url, hash is the sdist's
        sdists = [f for f in (files or []) if f["packagetype"] == "sdist"]
        if not sdists:
            raise ValueError(
                f"no sdist on PyPI for {version}; cannot build from source"
            )
        digest = sdists[0]["digests"]["sha256"]
        return {
            "version": version,
            "hash": "sha256-" + base64.b64encode(bytes.fromhex(digest)).decode(),
        }
    # fetchurl release tarball: substitute the version into the url
    if not coords["url"]:
        raise ValueError(f"{target.attr}: cannot determine how to re-point its fetcher")
    url = substitute_version("url", coords["url"], cur, version)
    out = run(["nix", "store", "prefetch-file", "--json", url]).stdout
    return {"url": url, "hash": json.loads(out)["hash"]}


# ── interpreter support (wheels only), from upstream wheel tags ───────────────


def supported_pythons(files):
    """Interpreters a release supports, from its upstream wheel tags.
    None: no wheels published at all (caller decides)."""
    supported = set()
    saw_wheel = False
    for f in files:
        name = f["filename"]
        if not name.endswith(".whl"):
            continue
        saw_wheel = True
        try:
            py, abi, _plat = name[: -len(".whl")].rsplit("-", 3)[1:]
        except ValueError:
            continue
        if abi == "none" and "py3" in py:
            return set(INTERPRETERS)  # pure
        if abi == "abi3":
            m = re.search(r"cp3(\d+)", py)
            if m:  # stable ABI: forward-compatible from its floor
                floor = int(m.group(1))
                supported |= {i for i in INTERPRETERS if int(i[3:]) >= floor}
        for i in INTERPRETERS:
            if f"cp3{i[3:]}" in py:
                supported.add(i)
    return supported if saw_wheel else None


# ── writing entries ──────────────────────────────────────────────────────────


def write_history(path, hist, dry):
    text = json.dumps(hist, indent=2, sort_keys=True) + "\n"
    if dry:
        print(f"--dry-run; would write {path.relative_to(REPO)}:")
        print(text, end="")
    else:
        path.write_text(text)


def add_version(target, hist, project, version, args):
    if version in hist.get(target.attr, {}):
        return f"{target.attr}=={version}: already in history.json"
    coords = src_coords(target)
    if version == coords["version"]:
        return f"{target.attr}=={version}: is the current version"

    files = None
    if target.pypi:
        files = pypi(f"https://pypi.org/pypi/{project}/{version}/json")["urls"]
    try:
        spec = fetch_spec(target, version, coords, files)
    except ValueError as e:
        if args.skip_unsupported:
            return f"{target.attr}=={version}: {e}; skipped"
        raise SystemExit(f"{target.attr}=={version}: {e}")

    # generic history gate: which of the set's build variants this entry is
    # limited to (spec `variants`, default all). Sets with a single variant
    # (CLIs) skip it. The default derivation is per-set; the only set with
    # variants today is wheels, where a variant is an interpreter derived from
    # upstream wheel tags. A future variant set plugs its own derivation here.
    chosen = None
    if target.variants is not None:
        if args.variants:
            chosen = set(args.variants)
        elif target.pypi:
            chosen = supported_pythons(files)  # None: no wheels; empty: none for ours
            if chosen is None:
                print(
                    f"{target.attr}=={version}: no upstream wheels to judge support; assuming all",
                    file=sys.stderr,
                )
                chosen = set(target.variants)
            elif not chosen:
                # upstream shipped wheels but none for our interpreters: the sdist
                # may still compile (xxhash 2.0.2 does) but old C API usually
                # won't (numpy 1.x), so make it an explicit call.
                msg = f"{target.attr}=={version}: no upstream cp313/cp314 wheels (unsupported interpreters)"
                if args.force:
                    chosen = set(target.variants)
                elif args.skip_unsupported:
                    return f"{msg}; skipped"
                else:
                    raise SystemExit(
                        f"{msg}; --force to add anyway, --variants to narrow"
                    )
        else:
            chosen = set(target.variants)  # variant set with no default derivation yet
        if set(chosen) != set(target.variants):
            spec["variants"] = sorted(chosen)

    if args.note:
        spec["note"] = args.note
    hist.setdefault(target.attr, {})[version] = spec
    tail = f" ({', '.join(sorted(chosen))})" if chosen else ""
    return f"{target.attr}=={version}: added{tail}"


def cmd_add(args):
    name, _, picked = args.spec.partition("==")
    target = resolve(name, args.set)
    hist = json.loads(target.history.read_text())
    project = args.project or target.attr

    if picked:
        versions = [picked]
    elif args.per_major or args.per_minor:
        # bulk mode reports unsupported candidates instead of aborting on the first
        args.skip_unsupported = not args.force
        coords = src_coords(target)
        # bulk mode orders candidates against the current version; an unparseable
        # one (bash 5.3p9, a 0-unstable-<date> pin) would compare as "older than
        # everything" and silently select nothing.
        cur = parse_version(coords["version"])
        if not cur:
            sys.exit(
                f'{target.attr}: current version "{coords["version"]}" is not a '
                "plain release, so --per-major/--per-minor cannot order against "
                "it; add versions explicitly"
            )
        since = parse_version(args.since) if args.since else ()
        groups = {}
        for v in list_versions(target, project, coords):
            t = parse_version(v)
            # only versions older than what we ship; newer is the updater's job
            if not t or t < since or t >= cur:
                continue
            key = t[:1] if args.per_major else t[:2]
            if key not in groups or t > groups[key][0]:
                groups[key] = (t, v)
        versions = [v for _, v in sorted(groups.values())]
        if not versions:
            print("nothing to add")
            return
    else:
        sys.exit("give ==<version>, --per-major, or --per-minor")

    for v in versions:
        print(add_version(target, hist, project, v, args))
    write_history(target.history, hist, args.dry_run)


def lockfile_pins(path):
    if path.suffix == ".txt":
        pins = []
        for line in path.read_text().splitlines():
            line = line.split("#", 1)[0].split(";", 1)[0].strip()
            m = re.fullmatch(r"([A-Za-z0-9._-]+)(?:\[[^]]*\])?==(\S+)", line)
            if m:
                pins.append((m.group(1), m.group(2)))
        return pins
    import tomllib

    data = tomllib.loads(path.read_text())
    pkgs = data.get("package") or data.get("packages") or []
    return [(p["name"], p["version"]) for p in pkgs if "version" in p]


def cmd_from_lockfile(args):
    args.variants = None
    args.force = False
    args.note = f"pinned by {args.path.name}"
    args.skip_unsupported = True  # a foreign lockfile must not hard-fail the run
    hists = {}  # history path -> loaded dict
    ours = 0
    for name, version in lockfile_pins(args.path):
        target = try_resolve(name, "wheel")  # lockfile pins are python deps
        if target is None:
            continue  # not shipped by us: PyPI serves it
        ours += 1
        hist = hists.setdefault(target.history, json.loads(target.history.read_text()))
        # the lockfile name is the PyPI project (may differ from the attr)
        print(add_version(target, hist, name, version, args))
    if not ours:
        print("no pins of shipped packages found")
    for path, hist in hists.items():
        write_history(path, hist, args.dry_run)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    add = sub.add_parser("add")
    add.add_argument("spec", metavar="attr[==version]")
    add.add_argument("--per-major", action="store_true")
    add.add_argument("--per-minor", action="store_true")
    add.add_argument("--since", metavar="V")
    add.add_argument(
        "--variants",
        type=lambda s: s.split(","),
        metavar="v1,v2",
        help="restrict to these build variants (wheels: interpreters, e.g. py313,py314)",
    )
    add.add_argument("--note")
    add.add_argument("--project", help="PyPI name when it differs from the attr")
    add.add_argument(
        "--set", choices=["wheel", "cli"], help="disambiguate a name in both sets"
    )
    add.add_argument("--force", action="store_true")
    add.add_argument("--skip-unsupported", action="store_true")
    add.add_argument("--dry-run", action="store_true")
    add.set_defaults(func=cmd_add)

    fl = sub.add_parser("from-lockfile")
    fl.add_argument("path", type=Path)
    fl.add_argument("--dry-run", action="store_true")
    fl.set_defaults(func=cmd_from_lockfile)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
