#!/usr/bin/env python3
# Driver for the repo's pin updates. What to bump and how lives in each
# package as passthru.updateScript (nix-update-script), discovered by eval;
# this script only drives:
# it runs each target isolated, adds the flake-input targets (which have no
# package file), runs the cross-file regen hooks after a bump (the rust fork's
# stage0 bootstrap pin, wasix-libc's witx submodule pins), and reports the
# summary plus fired updateNotes.
#
# Usage (or `nix run .#update -- ...`):
#   scripts/update.py              # update everything
#   scripts/update.py --only llvm wasix-libc
#   scripts/update.py --list       # show targets, no changes

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib import request

SYSTEM = "x86_64-linux"


def run(cmd, **kw):
    print(f"  $ {' '.join(cmd)}", file=sys.stderr)
    p = subprocess.run(cmd, text=True, capture_output=True, **kw)
    if p.returncode != 0:
        raise RuntimeError(
            f"{cmd[0]} exited {p.returncode}:\n{(p.stderr or p.stdout).strip()}"
        )
    return p


def repo_root():
    # Prefer the git working tree: under `nix run .#update` this file lives in the
    # store, but the pins we edit are in the checkout `nix run` was invoked from.
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            text=True,
            capture_output=True,
        )
        return Path(out.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return Path(__file__).resolve().parent.parent


REPO = repo_root()


def gh(path):
    req = request.Request(f"https://api.github.com/repos/{path}")
    req.add_header("Accept", "application/vnd.github+json")
    with request.urlopen(req) as r:
        return json.load(r)


def prefetch_github(owner, repo, rev):
    url = f"https://github.com/{owner}/{repo}/archive/{rev}.tar.gz"
    out = run(["nix", "store", "prefetch-file", "--json", "--unpack", url])
    return json.loads(out.stdout)["hash"]


def prefetch_url(url):
    out = run(["nix", "store", "prefetch-file", "--json", url])
    return json.loads(out.stdout)["hash"]


def raw_file(owner, repo, rev, path):
    url = f"https://raw.githubusercontent.com/{owner}/{repo}/{rev}/{path}"
    with request.urlopen(url) as r:
        return r.read().decode()


@dataclass
class Target:
    name: str
    backend: str  # "updateScript" | "flake"
    # flake: the flake.lock input name (`nix flake update <input>`)
    input: str = ""
    # updateScript (passthru.updateScript, discovered by eval):
    attr: str = ""
    command: tuple = ()
    file: str = ""  # repo-relative pin file, from meta.position


def regen_rust_bootstrap(t):
    # The rust fork's vendoring auto-tracks the src lockfiles (no FOD hash), so
    # the only pin that can drift is the stage0 bootstrap compiler; sync
    # version, url, and hash from the fork's src/stage0.
    path = REPO / "pkgs/toolchain/rust/toolchain.nix"
    text = path.read_text()
    version = re.search(r'version = "([^"]+)"', text).group(1)
    stage0 = raw_file("wasix-org", "rust", f"v{version}", "src/stage0")
    kv = dict(re.findall(r"^(\w+)=(.+)$", stage0, re.M))
    date, ver, server = kv["compiler_date"], kv["compiler_version"], kv["dist_server"]

    cur = re.search(
        r'pname = "rust-bootstrap";\s*\n\s*version = "([^"]+)"', text
    ).group(1)
    if cur == ver:
        return None

    url_literal = f"{server}/dist/{date}/rust-{ver}-${{hostTriple}}.tar.xz"
    new_hash = prefetch_url(
        f"{server}/dist/{date}/rust-{ver}-x86_64-unknown-linux-gnu.tar.xz"
    )
    old_hash = re.search(
        r'rust-bootstrap";.*?(sha256-[A-Za-z0-9+/=]+)', text, re.S
    ).group(1)

    text = re.sub(
        r'(pname = "rust-bootstrap";\s*\n\s*version = ")[^"]+(")',
        rf"\g<1>{ver}\g<2>",
        text,
    )
    text = re.sub(r'url = "[^"]*rust-[^"]*\.tar\.xz";', f'url = "{url_literal}";', text)
    text = text.replace(old_hash, new_hash, 1)
    path.write_text(text)
    return f"synced rust bootstrap -> {ver} ({date})"


def regen_libc_witx(t):
    # libc.nix pins the wasi/wasix witx specs (git submodules of wasix-libc)
    # separately from the libc src. A stale pin fails the libc build with
    # undeclared __wasi_* functions, so sync each pin to the submodule rev at
    # the new tag.
    path = REPO / "pkgs/toolchain/sysroot/libc.nix"
    text = path.read_text()
    tag = "v" + re.search(r'\bversion = "([^"]+)"', text).group(1)
    bumped = []
    for sub, owner, repo in [
        ("tools/wasi-headers/WASI", "WebAssembly", "WASI"),
        ("tools/wasix-headers/WASI", "wasix-org", "wasix-witx"),
    ]:
        sha = gh(f"wasix-org/wasix-libc/contents/{sub}?ref={tag}")["sha"]
        m = re.search(
            rf'repo = "{repo}";\s*\n\s*rev = "([^"]+)";\s*\n\s*hash = "([^"]+)"', text
        )
        if not m:
            raise RuntimeError(f"{repo}: witx pin block not found in libc.nix")
        if m.group(1) == sha:
            continue
        new_hash = prefetch_github(owner, repo, sha)
        text = text.replace(m.group(1), sha, 1).replace(m.group(2), new_hash, 1)
        bumped.append(f"{repo} -> {sha[:12]}")
    if not bumped:
        return None
    path.write_text(text)
    return "witx pins: " + ", ".join(bumped)


def regen_prune_wheel_rels(t):
    # The registry's publication release numbers (pkgs/python-registry/rels.json)
    # are keyed by upstream version; a nixpkgs bump that moves a wheel leaves
    # its old key behind (harmless: the lookup misses and rel resets to 1).
    path = REPO / "pkgs/python-registry/rels.json"
    rels = json.loads(path.read_text())
    if not rels:
        return None
    out = run(
        [
            "nix",
            "eval",
            "--json",
            f".#legacyPackages.{SYSTEM}.pythonRegistry.wheelVersions",
        ]
    ).stdout
    versions = json.loads(out)
    dropped = [
        f"{name} {v}"
        for name, by_version in sorted(rels.items())
        for v in sorted(by_version)
        if versions.get(name) != v
    ]
    pruned = {
        name: kept
        for name, by_version in rels.items()
        if (kept := {v: n for v, n in by_version.items() if versions.get(name) == v})
    }
    if not dropped:
        return None
    path.write_text(json.dumps(pruned, indent=2, sort_keys=True) + "\n")
    return f"dropped stale wheel rels: {', '.join(dropped)}"


# Cross-file regen hooks, keyed by target name: they synchronize other repo
# files with the new pin, which is driver logic, not package logic. What to
# bump and how lives in each package as passthru.updateScript.
REGEN_BY_NAME = {
    "rust-toolchain": regen_rust_bootstrap,
    "wasix-libc": regen_libc_witx,
    "nixpkgs": regen_prune_wheel_rels,
}

# Flake inputs (flake.lock) have no package file to carry an updateScript.
# Each is its own target so `--only nixpkgs` works like a package; nixpkgs
# drives the stdenv + every prev.X override package.
TARGETS = [
    Target("nixpkgs", "flake", input="nixpkgs"),
    Target("wasmer", "flake", input="wasmer"),
    Target("treefmt-nix", "flake", input="treefmt-nix"),
]


def repo_relative(path):
    # meta.position under a flake eval is inside the source store copy
    m = re.match(r"^/nix/store/[^/]+/(.*)$", path)
    if m:
        return m.group(1)
    try:
        return str(Path(path).relative_to(REPO))
    except ValueError:
        return path


def discovered_targets():
    # passthru.updateScript declarations (flake attr `updateScripts`), one
    # target per package, deduped across the per-profile ci attrs.
    out = run(
        ["nix", "eval", "--json", f".#legacyPackages.{SYSTEM}.updateScripts"]
    ).stdout
    targets = {}
    for attr, s in sorted(json.loads(out).items()):
        name = s.get("name") or attr.rsplit(".", 1)[-1]
        if name in targets:
            continue
        pos = s.get("position")
        targets[name] = Target(
            name,
            "updateScript",
            # attrPath: the declared target attr (e.g. the unwrapped package
            # behind a wrapper), else the attr the declaration was found on
            attr=f"legacyPackages.{SYSTEM}.{s.get('attrPath') or attr}",
            command=tuple(s["command"]),
            file=repo_relative(pos.rsplit(":", 1)[0]) if pos else "",
        )
    return list(targets.values())


# Each backend returns a one-line outcome for the summary (None: let the
# caller derive it from whether the working tree changed).


def run_update_script(t):
    cmd = list(t.command)
    # repo-relative script commands run from the checkout; store paths and
    # bare tool names pass through
    if "/" in cmd[0] and not cmd[0].startswith("/"):
        cmd[0] = str(REPO / cmd[0])
    # store-path commands (nix-update-script) may not be realized here
    if cmd[0].startswith("/nix/store/") and not os.path.exists(cmd[0]):
        run(["nix-store", "--realise", "/".join(cmd[0].split("/")[:4])])
    env = os.environ.copy()
    env["UPDATE_NIX_ATTR_PATH"] = t.attr
    if t.file:
        env["UPDATE_NIX_SOURCE_FILE"] = t.file
    print(f"  $ {' '.join(t.command)}", file=sys.stderr)
    p = subprocess.run(cmd, cwd=REPO, env=env, text=True, capture_output=True)
    sys.stderr.write(p.stderr)
    out = p.stdout.strip()
    for line in out.splitlines():
        print(f"  {line}")
    if p.returncode != 0:
        raise RuntimeError(
            f"{t.command[0]} exited {p.returncode}:\n{(p.stderr or p.stdout).strip()}"
        )
    # nix-update reports an early "Update a -> b in file" line; take the
    # last line that looks like an outcome, else fall back to the
    # tree-changed heuristic in main()
    for line in reversed(out.splitlines()):
        if line.startswith("up to date"):
            return line
        m = re.search(r"(\S+) -> (\S+?)( in /|$)", line)
        if m:
            if m.group(1) == m.group(2):
                return f"up to date ({m.group(1)})"
            return f"{m.group(1)} -> {m.group(2)}"
    return None


def flake_input_rev(name):
    node = json.loads((REPO / "flake.lock").read_text())["nodes"][name]["locked"]
    return node.get("rev") or node.get("ref") or ""


def update_flake_input(t):
    before = flake_input_rev(t.input)
    run(["nix", "flake", "update", t.input], cwd=REPO)
    after = flake_input_rev(t.input)
    outcome = f"{before[:10]} -> {after[:10]}" if before != after else "up to date"
    print(f"  {outcome}")
    return outcome


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", metavar="NAME")
    ap.add_argument("--list", action="store_true")
    ap.add_argument(
        "--summary-out",
        metavar="FILE",
        help="write a markdown summary (the auto-update PR body)",
    )
    args = ap.parse_args()

    targets = discovered_targets() + TARGETS
    if args.only:
        wanted = set(args.only)
        targets = [t for t in targets if t.name in wanted]
        unknown = wanted - {t.name for t in targets}
        if unknown:
            raise SystemExit(f"unknown target(s): {', '.join(sorted(unknown))}")

    if args.list:
        for t in targets:
            detail = t.input if t.backend == "flake" else " ".join(t.command)
            print(f"{t.name:16} {t.backend:12} {detail}")
        return

    def repo_status():
        return subprocess.run(
            ["git", "-C", str(REPO), "status", "--porcelain"],
            text=True,
            capture_output=True,
        ).stdout

    backends = {
        "updateScript": run_update_script,
        "flake": update_flake_input,
    }

    # captured before anything bumps: the `prior` side of the update notes
    priors = note_versions()

    # One flaky upstream must not abort the rest: isolate each target, collect
    # failures, and exit non-zero at the end so CI/the workflow notices.
    failures = []
    results = []  # (name, outcome) for the summary
    for t in targets:
        print(f"==> {t.name}")
        before = repo_status()
        try:
            outcome = backends[t.backend](t)
        except Exception as e:
            first = str(e).splitlines()[0][:120] if str(e) else "unknown error"
            print(f"  FAILED: {e}")
            failures.append(t.name)
            results.append((t.name, f"FAILED: {first}"))
            continue
        changed = repo_status() != before
        if outcome is None:
            outcome = "updated" if changed else "up to date"
        # Run the regen only on an actual bump (the working tree changed).
        regen = REGEN_BY_NAME.get(t.name)
        if regen and changed:
            try:
                summary = regen(t)
                print(f"  regen: {summary or 'no derived changes'}")
                if summary:
                    outcome += f"; {summary}"
            except Exception as e:
                print(f"  regen FAILED: {e}")
                failures.append(f"{t.name} (regen)")
                outcome += f"; regen FAILED: {str(e).splitlines()[0][:120]}"
        results.append((t.name, outcome))

    notes = fired_notes(priors)
    for n in notes:
        moved = f" ({n['prior']} -> {n['version']})" if n.get("prior") else ""
        print(f"\nNOTE: {n['name']}{moved}:\n  {n['message']}")

    if args.summary_out:
        Path(args.summary_out).write_text(summary_md(results, notes))

    if failures:
        print(f"\nFAILED: {', '.join(failures)}")
        sys.exit(1)


def note_versions():
    # versions of the packages carrying updateNotes, from before the run:
    # the `prior` side of each note's predicate
    try:
        out = run(
            ["nix", "eval", "--json", f".#legacyPackages.{SYSTEM}.updateNotes.versions"]
        ).stdout
        return json.loads(out)
    except Exception as e:
        print(f"WARN: note version eval failed: {e}", file=sys.stderr)
        return {}


def fired_notes(priors):
    # passthru.wasix.updateNotes whose predicate fires now that the pins
    # changed. Advisory only; deduped across the per-profile attrs.
    env = os.environ.copy()
    env["NOTE_PRIORS"] = json.dumps(priors)
    try:
        p = subprocess.run(
            [
                "nix",
                "eval",
                "--json",
                "--impure",
                f".#legacyPackages.{SYSTEM}.updateNotes.fired",
                "--apply",
                'f: f (builtins.fromJSON (builtins.getEnv "NOTE_PRIORS"))',
            ],
            cwd=REPO,
            env=env,
            text=True,
            capture_output=True,
            check=True,
        )
        fired = json.loads(p.stdout)
    except Exception as e:
        print(f"WARN: note check failed: {e}", file=sys.stderr)
        return []
    seen = {}
    for attr, notes in sorted(fired.items()):
        for n in notes:
            if n["message"] not in seen:
                seen[n["message"]] = {"name": attr.rsplit(".", 1)[-1], **n}
    return list(seen.values())


def summary_md(results, notes):
    md = "| target | result |\n|:--|:--|\n"
    # bumps and failures first, the up-to-date tail last
    order = sorted(results, key=lambda r: r[1].startswith("up to date"))
    for name, outcome in order:
        cell = outcome.replace("|", "\\|")
        if outcome.startswith("FAILED"):
            cell = f"❌ {cell}"
        md += f"| {name} | {cell} |\n"
    if notes:
        md += "\n### Update notes\n\n"
        for n in notes:
            moved = f" ({n['prior']} -> {n['version']})" if n.get("prior") else ""
            md += f"- **{n['name']}**{moved}: {n['message']}\n"
    return md


if __name__ == "__main__":
    main()
