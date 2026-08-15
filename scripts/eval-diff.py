#!/usr/bin/env python3
# Rebuild diff for CI. Evals the ci job set with nix-eval-jobs (attr ->
# drvPath), fetches the same map for a base commit from the cache bucket, and
# renders a markdown summary of what this change rebuilds. ci.yml uploads the
# map on pushes to main and reuses the raw eval for ci-build.sh, so the whole
# thing costs one eval per run.
#
# Only the drv-level view: meta/passthru-only changes do not move drvPaths and
# stay invisible here (that is the point; see docs/building.md "Before you commit").
#
# Usage:
#   eval-diff.py --jobs-out eval-jobs.jsonl --map-out eval-map.json \
#       --md-out rebuild-diff.md --base-rev <sha> [<sha> ...]
# The first base rev with a published map wins. With no --base-rev (or no map
# found) the diff is skipped but the map is still written. --jobs reuses an
# existing eval instead of running one; --base-map reads the base from a file.

import argparse
import collections
import json
import os
import subprocess
import sys
import threading
import urllib.error
import urllib.request

MAP_URL = "https://nix-cache.wasix.org/eval-maps/{rev}.json"
MAP_SCHEMA = 1
LIST_CAP = 250  # per section; a toolchain bump rebuilds everything

# A drv move under these prefixes rebuilds the world downstream.
MASS_REBUILD_PREFIXES = ("toolchain.",)

# Drvs that hash the whole source tree: they move on every diff and carry no
# rebuild signal. Kept as CI jobs, excluded from the diff (content-diff.py
# excludes them too).
TREE_TRACKING = ("checks.treefmt",)

# nix lines that name what an IFD input is doing, for the progress heartbeat
REALIZING = ("building ", "copying ", "waiting for lock", "substituting ")


def log(msg):
    print(msg, file=sys.stderr)


def default_flake():
    system = subprocess.run(
        ["nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem"],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()
    return f".#legacyPackages.{system}.ci"


def eval_workers():
    # EVAL_WORKERS is the same knob ci-build.sh takes, so a shared builder can
    # dial both down from one place.
    override = os.environ.get("EVAL_WORKERS")
    if override:
        return int(override)
    return 4


def eval_max_memory_size():
    # The ci set outgrows nix-eval-jobs' 4 GiB per-worker allowance; reaching it
    # restarts the worker and discards its evaluator state.
    override = os.environ.get("EVAL_MAX_MEMORY_SIZE")
    if override:
        return int(override)
    return 8192


def progress_ticker(jobs_path, activity, stop, every=30):
    # One vendor build keeps nix quiet for minutes, so pair the finished-job
    # count (stdout goes straight to the file) with what nix is realizing: a
    # climbing count is progress, a flat one under the same `waiting for lock`
    # line is a stall.
    while not stop.wait(every):
        try:
            with open(jobs_path) as f:
                done = sum(1 for _ in f)
        except OSError:
            done = 0
        log(f"  ... {done} jobs; {activity[0] or 'nothing being realized'}")


def eval_jobs(flake, jobs_path):
    # nix-eval-jobs comes from PATH (the .#scripts.rebuild-diff wrapper and the
    # devShell both pin it to the locked nixpkgs); `nix run nixpkgs#` would
    # fetch and unpack the registry's channel tarball on every CI run.
    # No --check-cache-status: it answers "is this cached" per job, and with
    # nothing cached (a bump) each answer re-walks the toolchain closure
    # through the one nix-daemon, which turns a 1-minute eval into an hour.
    # ci-build.sh gets the same list from one batched dry-run instead.
    # Returns the nix error on a top-level eval failure (broken flake): that
    # becomes report content, not a step crash; the build step fails the job
    # on the same error.
    cmd = [
        "nix-eval-jobs",
        "--flake",
        flake,
        # Workers parallelize instantiation, but each one holds a full nixpkgs
        # evaluation and they register drvs through a single daemon, so a small
        # fixed count beats scaling with cores.
        "--workers",
        str(eval_workers()),
        "--max-memory-size",
        str(eval_max_memory_size()),
        # meta rides along for ci-report.py: meta.position anchors failure
        # annotations at the package definition
        "--meta",
        "--option",
        "accept-flake-config",
        "true",
    ]
    log(f"$ {' '.join(cmd)}")
    # Stream nix's stderr rather than capturing it. An eval that has to realize
    # IFD inputs (a bump moving cargo or python rebuilds every crate vendor)
    # spends most of its time inside `building '...'`, and a captured pipe holds
    # every such line back until the eval ends, which reads as a hung step.
    # Only the tail is kept, for the error below.
    lines = collections.deque(maxlen=400)
    activity = [""]
    stop = threading.Event()
    threading.Thread(
        target=progress_ticker, args=(jobs_path, activity, stop), daemon=True
    ).start()
    try:
        with open(jobs_path, "w") as f:
            p = subprocess.Popen(
                cmd, stdout=f, stderr=subprocess.PIPE, text=True, bufsize=1
            )
            for line in p.stderr:
                sys.stderr.write(line)
                sys.stderr.flush()
                if line.startswith(REALIZING):
                    activity[0] = line.strip()
                lines.append(line.rstrip("\n"))
            returncode = p.wait()
    finally:
        stop.set()
    if returncode == 0:
        return None
    # the last error: block is the complete one (workers print partials)
    lines = list(lines)
    starts = [i for i, ln in enumerate(lines) if ln.startswith("error:")]
    tail = lines[starts[-1] :] if starts else lines[-30:]
    return "\n".join(tail[:60])


def load_map_from_jobs(jobs_path, rev):
    jobs, outputs, errors = {}, {}, {}
    with open(jobs_path) as f:
        for line in f:
            if not line.strip():
                continue
            obj = json.loads(line)
            # not obj["attr"]: the flat ci names contain dots, so nix-eval-jobs
            # renders them quoted ('"checks.abi-eh"')
            attr = ".".join(obj["attrPath"])
            if obj.get("error"):
                errors[attr] = obj["error"].splitlines()[0]
            else:
                jobs[attr] = obj["drvPath"]
                # output paths feed content-diff.py (rebuilt vs actually changed)
                outputs[attr] = obj.get("outputs") or {}
    return {
        "schema": MAP_SCHEMA,
        "rev": rev,
        "jobs": jobs,
        "outputs": outputs,
        "errors": errors,
    }


def fetch_base_map(revs, base_map_path):
    if base_map_path:
        with open(base_map_path) as f:
            return json.load(f)
    for rev in revs:
        url = MAP_URL.format(rev=rev)
        # explicit UA: Cloudflare intermittently 403s the python-urllib default
        req = urllib.request.Request(url, headers={"User-Agent": "wasinix-ci"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                m = json.load(r)
        except (urllib.error.URLError, TimeoutError) as e:
            code = getattr(e, "code", None)
            if code != 404:
                log(f"WARN: {url}: {e}")
            continue
        if m.get("schema") != MAP_SCHEMA:
            log(f"WARN: {url}: schema {m.get('schema')} != {MAP_SCHEMA}, skipping")
            continue
        return m
    return None


def section(title, attrs):
    if not attrs:
        return ""
    shown = sorted(attrs)[:LIST_CAP]
    lines = "\n".join(f"- `{a}`" for a in shown)
    more = len(attrs) - len(shown)
    if more:
        lines += f"\n- ... and {more} more"
    return f"\n<details><summary>{title} ({len(attrs)})</summary>\n\n{lines}\n\n</details>\n"


def diff_of(base, head):
    both = head["jobs"].keys() & base["jobs"].keys()
    return {
        "rebuilt": sorted(
            a
            for a in both
            if head["jobs"][a] != base["jobs"][a] and a not in TREE_TRACKING
        ),
        "added": sorted(head["jobs"].keys() - base["jobs"].keys()),
        "removed": sorted(base["jobs"].keys() - head["jobs"].keys()),
        "newErrors": {
            a: e for a, e in head["errors"].items() if a not in base["errors"]
        },
    }


def render(base, head):
    d = diff_of(base, head)
    rebuilt, added, removed = d["rebuilt"], d["added"], d["removed"]
    new_errors = d["newErrors"]

    total = len(head["jobs"])
    md = f"### Rebuild diff vs `{base['rev'][:12]}`\n\n"
    if not (rebuilt or added or removed or new_errors):
        return md + "No rebuilds.\n"
    md += (
        f"**{len(rebuilt)}** of **{total}** jobs rebuild"
        f" · {len(added)} added · {len(removed)} removed"
        f" · {len(new_errors)} new eval failures\n"
    )

    mass = sorted(a for a in rebuilt + added if a.startswith(MASS_REBUILD_PREFIXES))
    if mass:
        md += (
            f"\n> [!WARNING]\n> Toolchain drvs moved ({', '.join(f'`{a}`' for a in mass[:5])}"
            f"{', ...' if len(mass) > 5 else ''}): everything downstream rebuilds.\n"
        )

    md += section("Rebuilt", rebuilt)
    md += section("Added", added)
    md += section("Removed", removed)
    if new_errors:
        lines = "\n".join(
            f"- `{a}`: {e}" for a, e in sorted(new_errors.items())[:LIST_CAP]
        )
        md += (
            f"\n<details open><summary>New eval failures ({len(new_errors)})"
            f"</summary>\n\n{lines}\n\n</details>\n"
        )
    return md


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flake", default=None)
    ap.add_argument("--rev", default=None, help="rev recorded in the map")
    ap.add_argument("--jobs", help="existing nix-eval-jobs output, skips the eval")
    ap.add_argument("--jobs-out", help="where to write the nix-eval-jobs output")
    ap.add_argument("--map-out", required=True)
    ap.add_argument("--md-out", required=True)
    ap.add_argument("--summary-out", help="counts as json, for ci-report.py")
    ap.add_argument("--base-rev", nargs="*", default=[])
    ap.add_argument("--base-map", help="local base map file, for testing")
    ap.add_argument(
        "--base-map-out", help="save the fetched base map, for content-diff.py"
    )
    ap.add_argument(
        "--note-versions", help="updateNotes.versions json, published in the map"
    )
    ap.add_argument(
        "--priors-out", help="write the base map's note versions, for updateNotes.fired"
    )
    args = ap.parse_args()

    jobs_path = args.jobs
    eval_error = None
    if not jobs_path:
        if not args.jobs_out:
            sys.exit("need --jobs or --jobs-out")
        jobs_path = args.jobs_out
        eval_error = eval_jobs(args.flake or default_flake(), jobs_path)

    if eval_error is not None:
        # no map written: a broken eval must not be published as a base
        md = (
            "### Rebuild diff\n\nEval failed; no jobs to diff."
            f"\n\n```\n{eval_error}\n```\n"
        )
        with open(args.md_out, "w") as f:
            f.write(md)
        if args.summary_out:
            with open(args.summary_out, "w") as f:
                json.dump({"evalFailed": True}, f)
        log("eval failed; wrote error report")
        return

    rev = (
        args.rev
        or subprocess.run(
            ["git", "rev-parse", "HEAD"], check=True, text=True, capture_output=True
        ).stdout.strip()
    )
    head = load_map_from_jobs(jobs_path, rev)
    if args.note_versions:
        try:
            with open(args.note_versions) as f:
                head["noteVersions"] = json.load(f)
        except OSError as e:
            log(f"WARN: no note versions ({e})")
    with open(args.map_out, "w") as f:
        json.dump(head, f)
    log(
        f"{len(head['jobs'])} jobs, {len(head['errors'])} eval errors -> {args.map_out}"
    )

    base = fetch_base_map(args.base_rev, args.base_map)
    if base is not None and args.base_map_out:
        with open(args.base_map_out, "w") as f:
            json.dump(base, f)
    if args.priors_out:
        with open(args.priors_out, "w") as f:
            json.dump((base or {}).get("noteVersions", {}), f)
    if base is None:
        md = (
            "### Rebuild diff\n\nNo base eval map found"
            f" (tried {len(args.base_rev)} base rev(s)); diff skipped."
            " Maps are published on pushes to main.\n"
        )
    else:
        md = render(base, head)
    with open(args.md_out, "w") as f:
        f.write(md)

    if args.summary_out:
        summary = {"total": len(head["jobs"]), "baseRev": None}
        if base is not None:
            d = diff_of(base, head)
            summary["baseRev"] = base["rev"]
            summary.update({k: len(v) for k, v in d.items()})
        with open(args.summary_out, "w") as f:
            json.dump(summary, f)


if __name__ == "__main__":
    main()
