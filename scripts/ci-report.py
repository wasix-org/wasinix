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
import sys
import xml.etree.ElementTree as ET

MAX_FAILURES_SHOWN = 25
MAX_LOG_LINES = 30
MAX_LOG_CHARS = 3000

# nix's wording when a build fails because a dependency did, not on its own
DEP_FAILURE_MARKER = "dependencies of derivation"


def parse_junit(path):
    cases = []
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as e:
        print(f"WARN: no junit results ({e})", file=sys.stderr)
        return None
    for tc in root.iter("testcase"):
        failure = tc.find("failure")
        cases.append({
            # nix-eval-jobs quotes the dotted flat attr names
            "attr": tc.get("name", "").strip('"'),
            "class": tc.get("classname", ""),
            "message": failure.get("message", "") if failure is not None else None,
            "log": (failure.text or "") if failure is not None else None,
        })
    return cases


def classify(cases):
    counts = {}  # class -> [total, failed]
    failed = []
    for c in cases:
        t = counts.setdefault(c["class"], [0, 0])
        t[0] += 1
        if c["message"] is not None:
            t[1] += 1
            c["transitive"] = c["class"] == "Build" and (
                DEP_FAILURE_MARKER in c["message"] or DEP_FAILURE_MARKER in c["log"]
            )
            failed.append(c)
    return counts, failed


def title_of(counts, failed, diff, content):
    if counts is None:
        parts = ["build produced no results"]
    else:
        build_failed = [c for c in failed if c["class"] == "Build"]
        transitive = [c for c in build_failed if c["transitive"]]
        other_failed = len(failed) - len(build_failed)
        parts = []
        if build_failed:
            direct = len(build_failed) - len(transitive)
            parts.append(f"{direct} failed")
            if transitive:
                parts.append(f"{len(transitive)} failed via deps")
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


def excerpt(log):
    lines = [ln for ln in log.splitlines() if ln.strip()][-MAX_LOG_LINES:]
    return "\n".join(lines)[-MAX_LOG_CHARS:]


def render_md(title, counts, failed):
    md = f"### Build report\n\n**{title}**\n"
    if counts is None:
        return md + "\nThe build step wrote no JUnit results (cancelled or crashed).\n"
    md += "\n|stage|jobs|failed|\n|:--|--:|--:|\n"
    for cls in ("Eval", "Build", "Upload"):
        if cls in counts:
            total, bad = counts[cls]
            md += f"|{cls}|{total}|{bad or ''}|\n"
    shown = failed[:MAX_FAILURES_SHOWN]
    for c in shown:
        kind = " (dependency failed)" if c.get("transitive") else ""
        log = excerpt(c["log"])
        md += (
            f"\n<details><summary>❌ <code>{c['attr']}</code>"
            f" [{c['class']}]{kind}</summary>\n\n{c['message']}\n"
        )
        if log:
            md += f"\n```\n{log}\n```\n"
        md += "\n</details>\n"
    if len(failed) > len(shown):
        md += f"\n... and {len(failed) - len(shown)} more failures.\n"
    return md


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--junit", required=True)
    ap.add_argument("--diff-summary", help="summary json from eval-diff.py")
    ap.add_argument("--content-summary", help="summary json from content-diff.py")
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

    cases = parse_junit(args.junit)
    counts, failed = (None, []) if cases is None else classify(cases)
    title = title_of(counts, failed, diff, content)

    with open(args.json_out, "w") as f:
        json.dump({"title": title, "failed": len(failed)}, f)
    with open(args.md_out, "w") as f:
        f.write(render_md(title, counts, failed))
    print(title, file=sys.stderr)


if __name__ == "__main__":
    main()
