#!/usr/bin/env python3
# Render nix-fast-build's JUnit output and the eval-diff summary into the CI
# report: a one-line status (check run title) in report.json plus markdown
# details. Replaces dorny/test-reporter; test-report.yml turns these into a
# check run and a sticky PR comment.
#
# Tolerates a missing JUnit file (build cancelled before it wrote results) so
# the report still carries the eval side.

import argparse
import json
import re
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

MAX_FAILURES_SHOWN = 25
MAX_LOG_LINES = 30
MAX_LOG_CHARS = 3000


def parse_junit(path):
    cases = []
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as e:
        print(f"WARN: no junit results ({e})", file=sys.stderr)
        return None
    for tc in root.iter("testcase"):
        failure = tc.find("failure")
        cases.append(
            {
                # nix-eval-jobs quotes the dotted flat attr names
                "attr": tc.get("name", "").strip('"'),
                "class": tc.get("classname", ""),
                "message": failure.get("message", "") if failure is not None else None,
                "log": (failure.text or "") if failure is not None else None,
            }
        )
    return cases


def load_jobs_index(jobs_path):
    # attr -> {drv, position} from the nix-eval-jobs output (--meta)
    index = {}
    if not jobs_path:
        return index
    try:
        with open(jobs_path) as f:
            for line in f:
                if line.strip():
                    obj = json.loads(line)
                    if not obj.get("error"):
                        index[".".join(obj["attrPath"])] = {
                            "drv": obj["drvPath"],
                            "position": (obj.get("meta") or {}).get("position"),
                        }
    except OSError as e:
        print(f"WARN: no jobs index ({e})", file=sys.stderr)
    return index


def repo_relative_position(position):
    # meta.position under a flake eval is inside the source store copy;
    # positions elsewhere (nixpkgs drvs) have no file in this repo
    if not position:
        return None
    file, _, line = position.rpartition(":")
    m = re.match(r"^/nix/store/[^/]+/(.*)$", file)
    if not m:
        return None
    return {"path": m.group(1), "line": int(line) if line.isdigit() else 1}


LOG_ROOT = "/nix/var/log/nix/drvs"
# logs older than the eval output predate this run (warm store); they would
# misclassify GC'd successes as failures and stale failures as this run's
LOG_CUTOFF = 0.0


def fresh(path):
    try:
        return os.path.getmtime(path) >= LOG_CUTOFF
    except OSError:
        return False


def local_log(drv):
    # The junit never carries build logs (nix-fast-build's `nix log` output
    # lands on the console). A failed drv has a local log iff it ran itself;
    # a dependency failure leaves none, which is how we tell them apart.
    # Probe the log dir directly: `nix log` on a logless drv queries the
    # substituters over the network, hundreds of times on a toolchain break.
    base = drv.rsplit("/", 1)[-1]
    stem = f"{LOG_ROOT}/{base[:2]}/{base[2:]}"
    if not any(fresh(stem + ext) for ext in ("", ".bz2", ".zst")):
        return None
    p = subprocess.run(
        ["nix", "log", "--option", "substituters", "", drv],
        capture_output=True,
        text=True,
    )
    # log exists but is unreadable: still a direct failure, just no excerpt
    return p.stdout if p.returncode == 0 else ""


def classify(cases, index):
    counts = {}  # class -> [total, failed]
    failed = []
    for c in cases:
        t = counts.setdefault(c["class"], [0, 0])
        t[0] += 1
        if c["message"] is not None:
            t[1] += 1
            c["transitive"] = False
            if c["class"] == "Build" and c["attr"] in index:
                log = local_log(index[c["attr"]]["drv"])
                if log is not None:
                    c["log"] = log
                else:
                    # never ran itself: a dependency failed first
                    c["transitive"] = True
            failed.append(c)
    return counts, failed


def outputs_valid(drv):
    p = subprocess.run(
        ["nix-store", "--query", "--outputs", drv],
        capture_output=True,
        text=True,
    )
    return p.returncode == 0 and any(os.path.exists(o) for o in p.stdout.split())


def dependency_root_causes(failed, index):
    # A job that failed via deps points at a failing drv that is not itself
    # a job, so its log would surface nowhere (PR 46: a rustc bump broke 21
    # jobs, all "via deps", no log shown). Walk the failed jobs' drv
    # closures: a dep with a local log but no valid output is a build that
    # ran and failed. drv -> {name, log, jobs}
    checked = {}
    roots = {}
    job_drvs = {index[c["attr"]]["drv"] for c in failed if c["attr"] in index}
    for c in failed:
        if not c.get("transitive") or c["attr"] not in index:
            continue
        p = subprocess.run(
            ["nix-store", "--query", "--requisites", index[c["attr"]]["drv"]],
            capture_output=True,
            text=True,
        )
        if p.returncode != 0:
            print(f"WARN: requisites of {c['attr']}: {p.stderr}", file=sys.stderr)
            continue
        for drv in p.stdout.split():
            if not drv.endswith(".drv") or drv in job_drvs:
                continue
            if drv not in checked:
                checked[drv] = None
                log = local_log(drv)
                if log is not None and not outputs_valid(drv):
                    name = drv.rsplit("/", 1)[-1].split("-", 1)[1][: -len(".drv")]
                    checked[drv] = roots.setdefault(
                        drv, {"name": name, "log": log, "jobs": []}
                    )
            if checked[drv] is not None:
                checked[drv]["jobs"].append(c["attr"])
    return sorted(roots.values(), key=lambda r: r["name"])


def dedupe_notes(fired):
    # {attr: [{message, prior, version}]} -> one entry per message; the
    # per-profile attrs collapse to a package name
    merged = {}
    for attr, notes in (fired or {}).items():
        for n in notes:
            merged.setdefault(n["message"], {"name": attr.rsplit(".", 1)[-1], **n})
    return sorted(merged.values(), key=lambda n: n["name"])


def title_of(counts, failed, roots, diff, content):
    if diff and diff.get("evalFailed"):
        return "eval failed"
    if counts is None:
        parts = ["build produced no results"]
    else:
        build_failed = [c for c in failed if c["class"] == "Build"]
        transitive = [c for c in build_failed if c["transitive"]]
        other_failed = len(failed) - len(build_failed)
        parts = []
        if build_failed:
            direct = len(build_failed) - len(transitive)
            if direct:
                parts.append(f"{direct} failed")
            if transitive:
                via = (
                    roots[0]["name"]
                    if len(roots) == 1
                    else f"{len(roots)} deps"
                    if roots
                    else "deps"
                )
                parts.append(f"{len(transitive)} failed via {via}")
        if other_failed:
            parts.append(f"{other_failed} eval/upload failures")
        if not parts:
            parts.append(f"all {counts.get('Eval', [0])[0]} jobs ok")
        built = counts.get("Build", [0, 0])
        parts.append(f"{built[0] - built[1]} built")
    if diff and diff.get("baseRev"):
        parts.append(f"{diff['rebuilt']} rebuilt vs base")
        if diff.get("newErrors"):
            parts.append(f"{diff['newErrors']} new eval failures")
    if content and content.get("pairs"):
        parts.append(f"{content['identical']}/{content['pairs']} outputs identical")
    return " · ".join(parts)


def with_note_count(title, notes):
    if notes:
        return f"{title} · 📌 {len(notes)} update notes"
    return title


def excerpt(log):
    # drop nix's internal-json progress lines (FOD logs are full of them)
    lines = [
        ln for ln in log.splitlines() if ln.strip() and not ln.startswith("@nix ")
    ][-MAX_LOG_LINES:]
    return "\n".join(lines)[-MAX_LOG_CHARS:]


def render_notes(notes):
    if not notes:
        return ""
    md = f"\n<details open><summary>📌 Update notes ({len(notes)})</summary>\n\n"
    for n in notes:
        moved = f" ({n['prior']} -> {n['version']})" if n.get("prior") else ""
        md += f"- **{n['name']}**{moved}: {n['message']}\n"
    return md + "\n</details>\n"


def render_md(title, counts, failed, roots):
    md = f"### Build report\n\n**{title}**\n"
    if counts is None:
        return md + "\nThe build step wrote no JUnit results (cancelled or crashed).\n"
    md += "\n|stage|jobs|failed|\n|:--|--:|--:|\n"
    for cls in ("Eval", "Build", "Upload"):
        if cls in counts:
            total, bad = counts[cls]
            md += f"|{cls}|{total}|{bad or ''}|\n"

    # root causes first, with their logs; dependency victims as a bare list
    direct = [c for c in failed if not c.get("transitive")]
    transitive = [c for c in failed if c.get("transitive")]
    shown = direct[:MAX_FAILURES_SHOWN]
    for c in shown:
        log = excerpt(c["log"])
        md += (
            f"\n<details open><summary>❌ <code>{c['attr']}</code>"
            f" [{c['class']}]</summary>\n\n{c['message']}\n"
        )
        if log:
            md += f"\n```\n{log}\n```\n"
        md += "\n</details>\n"
    if len(direct) > len(shown):
        md += f"\n... and {len(direct) - len(shown)} more direct failures.\n"
    for r in roots[:MAX_FAILURES_SHOWN]:
        jobs = ", ".join(f"`{j}`" for j in r["jobs"][:5])
        if len(r["jobs"]) > 5:
            jobs += f" and {len(r['jobs']) - 5} more"
        md += (
            f"\n<details open><summary>❌ <code>{r['name']}</code>"
            f" [dependency]</summary>\n\nfailed dependency of {jobs}\n"
        )
        if log := excerpt(r["log"]):
            md += f"\n```\n{log}\n```\n"
        md += "\n</details>\n"
    if len(roots) > MAX_FAILURES_SHOWN:
        md += f"\n... and {len(roots) - MAX_FAILURES_SHOWN} more failed dependencies.\n"
    if transitive:
        names = "\n".join(
            f"- `{c['attr']}`" for c in transitive[: MAX_FAILURES_SHOWN * 10]
        )
        if len(transitive) > MAX_FAILURES_SHOWN * 10:
            names += f"\n- ... and {len(transitive) - MAX_FAILURES_SHOWN * 10} more"
        md += (
            f"\n<details><summary>failed because a dependency failed"
            f" ({len(transitive)})</summary>\n\n{names}\n\n</details>\n"
        )
    return md


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--junit", required=True)
    ap.add_argument("--jobs", help="nix-eval-jobs output, for drv paths (nix log)")
    ap.add_argument("--diff-summary", help="summary json from eval-diff.py")
    ap.add_argument("--content-summary", help="summary json from content-diff.py")
    ap.add_argument("--notes", help="fired updateNotes json from nix eval")
    ap.add_argument("--md-out", required=True)
    ap.add_argument("--json-out", required=True)
    args = ap.parse_args()

    def load_optional(path):
        if not path:
            return None
        try:
            with open(path) as f:
                return json.load(f)
        except OSError as e:
            print(f"WARN: {e}", file=sys.stderr)
            return None

    diff = load_optional(args.diff_summary)
    content = load_optional(args.content_summary)
    notes = dedupe_notes(load_optional(args.notes))

    cases = parse_junit(args.junit)
    index = load_jobs_index(args.jobs)
    if args.jobs:
        global LOG_CUTOFF
        try:
            LOG_CUTOFF = os.path.getmtime(args.jobs)
        except OSError:
            pass
    counts, failed = (None, []) if cases is None else classify(cases, index)
    roots = dependency_root_causes(failed, index)
    title = with_note_count(title_of(counts, failed, roots, diff, content), notes)

    # check-run annotations: direct failures anchored at the package
    # definition (meta.position, which the overlay loader stamps to our
    # files); transitive victims stay in the summary list
    annotations = []
    for c in failed:
        if c.get("transitive"):
            continue
        pos = repo_relative_position((index.get(c["attr"]) or {}).get("position"))
        if pos is None:
            continue
        annotations.append(
            {
                "path": pos["path"],
                "line": pos["line"],
                "title": f"{c['attr']} [{c['class']}]",
                "message": (c["message"] + "\n\n" + excerpt(c["log"]))[:2000],
            }
        )

    with open(args.json_out, "w") as f:
        json.dump(
            {"title": title, "failed": len(failed), "annotations": annotations}, f
        )
    with open(args.md_out, "w") as f:
        f.write(render_md(title, counts, failed, roots) + render_notes(notes))
    print(title, file=sys.stderr)


if __name__ == "__main__":
    main()
