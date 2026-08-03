#!/usr/bin/env python3
# Generate pkgs/cargo-registry/crates.json: the concrete fork version set the
# mint publishes, each with its upstream .crate hash. The set is resolved from
# .#cargoRegistry.pinConstraints: for each mintable crate, the crates.io
# releases matching its edits.nix `versions` constraint. Idempotent: existing
# hashes are reused unless --refresh, and versions no longer matched are pruned.
#
#   nix run .#scripts.crate-pins            # add missing, prune stale
#   nix run .#scripts.crate-pins -- --refresh   # re-hash everything
import concurrent.futures
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.request import urlopen

SYSTEM = "x86_64-linux"
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
TERM = re.compile(r"^\s*(>=|<=|=|<|>)\s*(\d+\.\d+\.\d+)\s*$")
CMP = {
    ">=": lambda a, b: a >= b,
    "<=": lambda a, b: a <= b,
    "=": lambda a, b: a == b,
    "<": lambda a, b: a < b,
    ">": lambda a, b: a > b,
}


def key(v):
    return tuple(int(x) for x in SEMVER.match(v).groups())


def index_path(name):
    n = name.lower()
    if len(n) == 1:
        return f"1/{n}"
    if len(n) == 2:
        return f"2/{n}"
    if len(n) == 3:
        return f"3/{n[0]}/{n}"
    return f"{n[:2]}/{n[2:4]}/{n}"


def crates_io_releases(name):
    """Non-yanked plain-semver releases on crates.io, low->high."""
    with urlopen(f"https://index.crates.io/{index_path(name)}") as r:
        vers = [
            e["vers"]
            for e in (json.loads(line) for line in r.read().decode().splitlines())
            if not e.get("yanked") and SEMVER.match(e["vers"])
        ]
    return sorted(vers, key=key)


def matches(constraints, v):
    """v satisfies any constraint (OR); a constraint is comma-AND of comparators."""
    kv = key(v)
    for c in constraints:
        ok = True
        for term in c.split(","):
            m = TERM.match(term)
            if not m:
                raise SystemExit(f"crate-pins: bad constraint term {term!r} in {c!r}")
            if not CMP[m.group(1)](kv, key(m.group(2))):
                ok = False
        if ok:
            return True
    return False


def wanted_versions(crate, constraints):
    """crates.io releases matching the crate's `versions` constraint. No floor
    logic: the mint decides which resolve to an edit; a matched version that
    turns out stock is simply not minted."""
    return [v for v in crates_io_releases(crate) if matches(constraints, v)]


def sri(crate, version):
    url = f"https://static.crates.io/crates/{crate}/{version}/download"
    raw = (
        subprocess.run(
            ["nix-prefetch-url", "--unpack", "--type", "sha256", url],
            text=True,
            capture_output=True,
            check=True,
        )
        .stdout.strip()
        .splitlines()[-1]
    )
    return subprocess.run(
        ["nix", "hash", "convert", "--hash-algo", "sha256", "--to", "sri", raw],
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()


def main():
    refresh = "--refresh" in sys.argv[1:]
    repo = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
    )
    path = repo / "pkgs/cargo-registry/crates.json"
    current = json.loads(path.read_text()) if path.exists() else {}

    constraints = json.loads(
        subprocess.run(
            [
                "nix",
                "eval",
                "--json",
                f".#legacyPackages.{SYSTEM}.cargoRegistry.pinConstraints",
            ],
            text=True,
            capture_output=True,
            check=True,
        ).stdout
    )

    wanted = {c: wanted_versions(c, cs) for c, cs in constraints.items()}

    todo = [
        (c, v)
        for c, versions in wanted.items()
        for v in versions
        if refresh or v not in current.get(c, {})
    ]
    for c, v in todo:
        print(f"fetching {c} {v}", file=sys.stderr)

    hashes = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        for (c, v), h in zip(todo, ex.map(lambda cv: sri(*cv), todo)):
            hashes.setdefault(c, {})[v] = h

    out = {
        c: {v: hashes.get(c, {}).get(v) or current[c][v] for v in versions}
        for c, versions in wanted.items()
    }

    pruned = [
        f"{c} {v}"
        for c, versions in current.items()
        for v in versions
        if v not in wanted.get(c, [])
    ]

    path.write_text(json.dumps(out, indent=2, sort_keys=True) + "\n")
    n = sum(len(v) for v in out.values())
    print(
        f"crate-pins: {n} pins ({len(todo)} fetched)"
        + (f", pruned {', '.join(pruned)}" if pruned else "")
    )


if __name__ == "__main__":
    main()
