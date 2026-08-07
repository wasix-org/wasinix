#!/usr/bin/env python3
# Driver for the repo's pin updates. What to bump and how lives in each
# package as passthru.updateScript (nix-update-script), discovered by eval;
# this script only drives:
# it runs each target isolated, adds the flake-input targets (which have no
# package file), runs the repo-wide steps a bump implies (retain the outgoing
# major in the registry-history tables, prune rels.json keys nothing serves,
# then the package-declared retentionHooks), and reports the summary plus fired
# updateNotes.
# A pin derived from another pin belongs to its package: see
# pkgs/toolchain/rust/update.py and pkgs/toolchain/sysroot/update.py.
#
# Usage (or `nix run .#scripts.update -- ...`):
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

from updater_lib import REPO, gh, prefetch_url, run  # noqa: F401

SYSTEM = "x86_64-linux"


@dataclass
class Target:
    name: str
    backend: str  # "updateScript" | "flake"
    # flake: the flake.lock input name (`nix flake update <input>`)
    input: str = ""
    # updateScript (passthru.updateScript, discovered by eval):
    attr: str = ""
    command: tuple = ()
    command_drv_paths: tuple = ()
    file: str = ""  # repo-relative pin file, from meta.position
    version: str = ""


def prune_rels():
    # Publication release numbers (rels.json) are keyed by attr path then
    # upstream version; any bump that moves a package leaves its old key
    # behind (harmless: the lookup misses and rel resets to 1). Runs after
    # every update run; free while rels.json is empty.
    path = REPO / "rels.json"
    rels = json.loads(path.read_text())
    if not rels:
        return None
    out = run(
        [
            "nix",
            "eval",
            "--json",
            f".#legacyPackages.{SYSTEM}.relVersions",
        ]
    ).stdout
    versions = json.loads(out)
    dropped = [
        f"{key} {v}"
        for key, by_version in sorted(rels.items())
        for v in sorted(by_version)
        if v not in versions.get(key, [])
    ]
    pruned = {
        key: kept
        for key, by_version in rels.items()
        if (kept := {v: n for v, n in by_version.items() if v in versions.get(key, [])})
    }
    if not dropped:
        return None
    path.write_text(json.dumps(pruned, indent=2, sort_keys=True) + "\n")
    return f"dropped stale rels: {', '.join(dropped)}"


WHEEL_HISTORY = REPO / "pkgs/overlay/python-packages/history.json"
# {"wheel": {attr: info}, "cli": {overlay-attr: info}} where info is
# {"version", "retention"}, current (non-history) state captured in main()
# before anything bumps. Raw versions, matching the history.json keys the
# loader mints from; retention is the package's passthru.wasix.retention.
history_priors = {}


def current_versions():
    result = {"wheel": {}, "cli": {}}
    # wheels: exclude history entries (<attr>-<version> keys, from history.json)
    whist = json.loads(WHEEL_HISTORY.read_text())
    whist_keys = {f"{a}-{v}" for a, vs in whist.items() for v in vs}
    wout = run(
        [
            "nix",
            "eval",
            "--json",
            f".#legacyPackages.{SYSTEM}.pythonWheels",
            "--apply",
            "ws: builtins.mapAttrs (_: s: builtins.mapAttrs (_: w: "
            "{ version = w.version; retention = w.passthru.wasix.retention or null; }) s) ws",
        ]
    ).stdout
    for versions in json.loads(wout).values():
        for attr, info in versions.items():
            if attr not in whist_keys:
                result["wheel"].setdefault(attr, info)
    # CLIs: non-history wasmerPackages, keyed by overlay attr (the history key)
    cout = run(
        [
            "nix",
            "eval",
            "--json",
            f".#legacyPackages.{SYSTEM}.wasmerPackages",
            "--apply",
            "ws: builtins.mapAttrs (_: p: { overlay = p.overlayName; "
            "history = p.passthru.wasmer.history or false; version = p.version; "
            "retention = p.passthru.wasix.retention or null; }) ws",
        ]
    ).stdout
    for info in json.loads(cout).values():
        if not info["history"]:
            result["cli"].setdefault(
                info["overlay"],
                {"version": info["version"], "retention": info["retention"]},
            )
    return result


# passthru.wasix.retention: how far down the version a bump must move before the
# outgoing version is retained. "major" (the default) keeps the last of each
# major, "minor" the last of each minor, "none" opts a package out entirely.
# The number is how many leading components define a series.
RETENTION_LEVELS = {"none": 0, "major": 1, "minor": 2}
DEFAULT_RETENTION = "major"


def retention_crossed(prior, now, level):
    # Retain the outgoing version when the components down to `level` change.
    # Only plain dotted releases have comparable components. A non-release
    # version (bash 5.3p9, a 0-unstable-<date> pin) has no series to cross, and
    # treating its whole string as one would fire on every bump.
    n = RETENTION_LEVELS[level]
    if n == 0:
        return False
    plain = re.compile(r"\d+(\.\d+)*\Z")
    if not (plain.match(prior) and plain.match(now)):
        return False
    return prior.split(".")[:n] != now.split(".")[:n]


def retention_note(prior, level):
    n = RETENTION_LEVELS[level]
    series = ".".join(prior.split(".")[:n])
    return f"latest {series}.x (outgoing {'major' if n == 1 else 'minor'})"


def regen_history():
    # Retention keeps the outgoing version behind in the registry-history table
    # (wheels and CLIs alike) so pinned consumers keep resolving. How far a bump
    # must move to trigger it is the package's passthru.wasix.retention
    # (default: latest-per-major); "none" opts out (e.g. icu-data, whose majors
    # are already first-class attrs).
    #
    # Not keyed to a target: what matters is that a SERVED version moved, and a
    # package pinning its own src moves on its own updateScript, not on the
    # nixpkgs bump. prune_rels drops the outgoing version's rel key either way,
    # so retention has to cover the same ground or the two disagree.
    if not history_priors:
        return None
    cur = current_versions()
    lines = []
    failed = []
    for kind, priors in history_priors.items():
        for attr, prior_info in sorted(priors.items()):
            prior = prior_info["version"]
            now_info = cur[kind].get(attr)
            if not now_info:
                continue
            now = now_info["version"]
            policy = now_info.get("retention") or DEFAULT_RETENTION
            if policy not in RETENTION_LEVELS:
                failed.append(
                    f"{attr}: unknown retention policy {policy!r} "
                    f"(expected one of {', '.join(RETENTION_LEVELS)})"
                )
                continue
            if not retention_crossed(prior, now, policy):
                continue
            p = subprocess.run(
                [
                    sys.executable,
                    str(REPO / "scripts/history.py"),
                    "add",
                    f"{attr}=={prior}",
                    "--set",
                    kind,
                    "--skip-unsupported",
                    "--note",
                    retention_note(prior, policy),
                ],
                cwd=REPO,
                text=True,
                capture_output=True,
            )
            report = (p.stdout or p.stderr).strip().splitlines()
            last = report[-1] if report else f"history.py exited {p.returncode}"
            # A failed append must not pass as a result: prune_rels runs after
            # retention and drops the outgoing version's rel key once nothing
            # serves it, which is exactly what this hook exists to prevent.
            if p.returncode != 0:
                failed.append(f"{attr}=={prior}: {last}")
            else:
                lines.append(last)
    if failed:
        raise RuntimeError("; ".join(failed))
    return "; ".join(lines) if lines else None


# Flake inputs (flake.lock) have no package file to carry an updateScript.
# Each is its own target so `--only nixpkgs` works like a package; nixpkgs
# drives the stdenv + every prev.X override package.
TARGETS = [
    Target("nixpkgs", "flake", input="nixpkgs"),
    Target("wasmer", "flake", input="wasmer"),
    Target("treefmt-nix", "flake", input="treefmt-nix"),
    # bumping this rebuilds the whole haskell closure and needs the wasm patches
    # re-verified.
    Target("ghc-wasm-meta", "flake", input="ghc-wasm-meta"),
    # the overlay registry's crates.json, refreshed from crates.io against each
    # mintable crate's `versions` constraint (no package file to carry it).
    Target("crate-pins", "crate-pins"),
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
            command_drv_paths=tuple(s["commandDrvPaths"]),
            file=repo_relative(pos.rsplit(":", 1)[0]) if pos else "",
            version=s.get("version") or "",
        )
    return list(targets.values())


def discovered_hooks():
    # passthru.wasix.retentionHook declarations (flake attr `retentionHooks`),
    # deduped by command across the per-profile ci attrs. Run after the
    # repo-wide history/prune steps so a package can re-sync a listing it
    # derives from the pins.
    out = run(
        ["nix", "eval", "--json", f".#legacyPackages.{SYSTEM}.retentionHooks"]
    ).stdout
    hooks = {}
    for attr, h in sorted(json.loads(out).items()):
        cmd = tuple(h["command"])
        hooks.setdefault(cmd, attr.rsplit(".", 1)[-1])
    return [(name, list(cmd)) for cmd, name in hooks.items()]


def run_retention_hook(name, command):
    cmd = list(command)
    if "/" in cmd[0] and not cmd[0].startswith("/"):
        cmd[0] = str(REPO / cmd[0])
    print(f"==> hook: {name}")
    print(f"  $ {' '.join(command)}", file=sys.stderr)
    p = subprocess.run(cmd, cwd=REPO, text=True, capture_output=True)
    sys.stderr.write(p.stderr)
    out = p.stdout.strip()
    for line in out.splitlines():
        print(f"  {line}")
    if p.returncode != 0:
        raise RuntimeError(
            f"{command[0]} exited {p.returncode}:\n{(p.stderr or p.stdout).strip()}"
        )
    lines = out.splitlines()
    return lines[-1] if lines else None


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
        drv_path = t.command_drv_paths[0]
        path = drv_path or "/".join(cmd[0].split("/")[:4])
        run(["nix-store", "--realise", path])
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
        # a --version-regex that excludes every available tag (prereleases
        # only, e.g. s3-server) means nothing to bump, not a broken updater
        if "No version matched the regex" in p.stderr:
            return "up to date"
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
    outcome = (
        f"{before[:10]} -> {after[:10]}"
        if before != after
        else f"up to date ({after[:10]})"
    )
    print(f"  {outcome}")
    return outcome


def update_crate_pins(t):
    # The overlay registry's crates.json is a pin: crate-pins re-enumerates
    # crates.io for each mintable crate's `versions` constraint, adding new
    # matching releases and pruning gone ones so the mint tracks upstream.
    p = run([sys.executable, str(REPO / "scripts/crate-pins.py")])
    line = next(
        (ln for ln in p.stdout.splitlines() if ln.startswith("crate-pins:")), None
    )
    if line:
        print(f"  {line}")
    return line.split(":", 1)[1].strip() if line else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", nargs="*", metavar="NAME")
    ap.add_argument("--list", action="store_true")
    ap.add_argument(
        "--list-json",
        action="store_true",
        help="target names as a JSON array (the update workflow's matrix)",
    )
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

    if args.list_json:
        print(json.dumps([t.name for t in targets]))
        return

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
        "crate-pins": update_crate_pins,
    }

    def normalize_outcome(t, outcome, changed):
        crate_state = re.fullmatch(r"(\d+ pins) \(0 fetched\)", outcome)
        if t.backend == "crate-pins" and not changed and crate_state:
            return f"up to date ({crate_state.group(1)})"
        if outcome == "up to date" and t.version:
            return f"up to date ({t.version})"
        return outcome

    # captured before anything bumps: the `prior` side of the update notes
    priors = note_versions()
    # and of regen_history, below. Any target can move a served version.
    history_priors.update(current_versions())

    # One flaky upstream must not abort the rest: isolate each target, collect
    # failures, and exit non-zero at the end so CI/the workflow notices.
    failures = []
    results = []  # (name, outcome) for the summary
    any_changed = False  # gates the global regen steps below
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
        any_changed = any_changed or changed
        if outcome is None:
            outcome = "updated" if changed else "up to date"
        results.append((t.name, normalize_outcome(t, outcome, changed)))

    # Retain before pruning: prune_rels drops the rel key of any version no
    # longer served, which is exactly the version retention just brought back.
    if any_changed:
        try:
            retained = regen_history()
            if retained:
                results.append(("history", retained))
        except Exception as e:
            failures.append("history retention")
            results.append(("history", f"FAILED: {str(e).splitlines()[0][:120]}"))

    try:
        pruned = prune_rels()
        if pruned:
            results.append(("rels", pruned))
    except Exception as e:
        failures.append("rels prune")
        results.append(("rels", f"FAILED: {str(e).splitlines()[0][:120]}"))

    # Package-declared re-sync, last: a hook regenerates a listing derived from
    # the pins (icu's versions.nix) once history and prune have settled. Each is
    # isolated like a target, and reads the pins directly, so a hook can repair
    # a listing even when a stale one breaks the repo eval.
    if any_changed:
        for name, command in discovered_hooks():
            before = repo_status()
            try:
                outcome = run_retention_hook(name, command)
            except Exception as e:
                failures.append(f"hook:{name}")
                results.append((name, f"FAILED: {str(e).splitlines()[0][:120]}"))
                continue
            # Report only when the hook changed something; its no-op line (icu's
            # "versions.nix up to date") still prints to the log but would be
            # noise in the summary on every PR, unlike history/rels above.
            if repo_status() != before:
                results.append((name, outcome or "re-synced"))

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
    cmd = [
        "nix",
        "eval",
        "--json",
        "--impure",
        f".#legacyPackages.{SYSTEM}.updateNotes.fired",
        "--apply",
        'f: f (builtins.fromJSON (builtins.getEnv "NOTE_PRIORS"))',
    ]
    for attempt in range(2):
        try:
            fired = json.loads(run(cmd, cwd=REPO, env=env).stdout)
            break
        except Exception as e:
            if attempt == 0:
                print("WARN: note check failed; retrying once", file=sys.stderr)
            else:
                print(f"WARN: note check failed after retry: {e}", file=sys.stderr)
                return []
    seen = {}
    for attr, notes in sorted(fired.items()):
        # wasmerPackages.<n>.webc names as <n> (which may contain dots)
        base = attr.removesuffix(".webc")
        name = (
            base.removeprefix("wasmerPackages.")
            if base.startswith("wasmerPackages.")
            else base.rsplit(".", 1)[-1]
        )
        for n in notes:
            if n["message"] not in seen:
                seen[n["message"]] = {"name": name, **n}
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
