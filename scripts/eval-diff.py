#!/usr/bin/env python3
# Rebuild diff for CI. Evals the ci job set with nix-eval-jobs (attr ->
# drvPath), fetches the same map for a base commit from the cache bucket, and
# renders a markdown summary of what this change rebuilds. ci.yml uploads the
# map on pushes to main and reuses the raw eval for ci-build.sh, so the whole
# thing costs one eval per run.
#
# Only the drv-level view: meta/passthru-only changes do not move drvPaths and
# stay invisible here (that is the point; see CLAUDE.md "Checking your work").
#
# Usage:
#   eval-diff.py --jobs-out eval-jobs.jsonl --map-out eval-map.json \
#       --md-out rebuild-diff.md --base-rev <sha> [<sha> ...]
# The first base rev with a published map wins. With no --base-rev (or no map
# found) the diff is skipped but the map is still written. --jobs reuses an
# existing eval instead of running one; --base-map reads the base from a file.

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request

MAP_URL = "https://nix-cache.wasix.org/eval-maps/{rev}.json"
MAP_SCHEMA = 1
LIST_CAP = 250  # per section; a toolchain bump rebuilds everything

# A drv move under these prefixes rebuilds the world downstream.
MASS_REBUILD_PREFIXES = ("foundation.",)


def log(msg):
    print(msg, file=sys.stderr)


def default_flake():
    system = subprocess.run(
        ["nix", "eval", "--raw", "--impure", "--expr", "builtins.currentSystem"],
        check=True, text=True, capture_output=True,
    ).stdout.strip()
    return f".#legacyPackages.{system}.ci"


def eval_jobs(flake, jobs_path):
    # --check-cache-status so ci-build.sh can reuse this eval for its
    # build-dep push list; stderr stays on the terminal for progress.
    cmd = [
        "nix", "run", "nixpkgs#nix-eval-jobs", "--",
        "--flake", flake,
        "--check-cache-status",
        "--option", "accept-flake-config", "true",
    ]
    log(f"$ {' '.join(cmd)}")
    with open(jobs_path, "w") as f:
        p = subprocess.run(cmd, stdout=f)
    if p.returncode != 0:
        sys.exit(f"nix-eval-jobs exited {p.returncode}")


def load_map_from_jobs(jobs_path, rev):
    jobs, errors = {}, {}
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
    return {"schema": MAP_SCHEMA, "rev": rev, "jobs": jobs, "errors": errors}


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
    return (
        f"\n<details><summary>{title} ({len(attrs)})</summary>\n\n{lines}\n\n</details>\n"
    )


def diff_of(base, head):
    both = head["jobs"].keys() & base["jobs"].keys()
    return {
        "rebuilt": sorted(a for a in both if head["jobs"][a] != base["jobs"][a]),
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
        return md + "No rebuilds: eval identical to base.\n"
    md += (
        f"**{len(rebuilt)}** of **{total}** jobs rebuild"
        f" · {len(added)} added · {len(removed)} removed"
        f" · {len(new_errors)} new eval failures\n"
    )

    mass = sorted(
        a for a in rebuilt + added if a.startswith(MASS_REBUILD_PREFIXES)
    )
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
    args = ap.parse_args()

    jobs_path = args.jobs
    if not jobs_path:
        if not args.jobs_out:
            sys.exit("need --jobs or --jobs-out")
        jobs_path = args.jobs_out
        eval_jobs(args.flake or default_flake(), jobs_path)

    rev = args.rev or subprocess.run(
        ["git", "rev-parse", "HEAD"], check=True, text=True, capture_output=True
    ).stdout.strip()
    head = load_map_from_jobs(jobs_path, rev)
    with open(args.map_out, "w") as f:
        json.dump(head, f)
    log(f"{len(head['jobs'])} jobs, {len(head['errors'])} eval errors -> {args.map_out}")

    base = fetch_base_map(args.base_rev, args.base_map)
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
