#!/usr/bin/env python3
"""Rank the next WASIX Python coverage additions from vendored survey data."""

import argparse
import json
import os
import re
import sys


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
VERSION_SURVEY_DATA = os.path.join(ROOT, "..", "version-survey", "data")


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def load(name):
    with open(os.path.join(DATA, name)) as f:
        return json.load(f)


def load_version_survey(name):
    with open(os.path.join(VERSION_SURVEY_DATA, name)) as f:
        return json.load(f)


def scope_reason(name, scope):
    if name in scope["packages"]:
        return scope["packages"][name]
    for prefix, reason in scope["prefixes"].items():
        if name.startswith(prefix):
            return reason
    return None


def closure_blockers(root, graph, classified, optional, shipped):
    blockers, unknown, seen = set(), set(), set()
    stack = [root]
    while stack:
        package = stack.pop()
        if package in seen:
            continue
        seen.add(package)
        meta = classified.get(package)
        if meta is None:
            unknown.add(package)
        elif (
            meta.get("final") == "native"
            and package not in optional
            and package not in shipped
        ):
            blockers.add(package)
        stack.extend(graph.get(package, []))
    return blockers, unknown


def rank_native(blocked, downloads, scope, limit):
    selected, rows = set(), []
    while len(rows) < limit:
        choices = {}
        for root, blockers in blocked.items():
            remaining = blockers - selected
            if len(remaining) == 1:
                candidate = next(iter(remaining))
                choices.setdefault(candidate, []).append(root)
        if not choices:
            break
        candidate, roots = max(
            choices.items(),
            key=lambda item: (sum(downloads[root] for root in item[1]), item[0]),
        )
        selected.add(candidate)
        rows.append(
            {
                "package": candidate,
                "downloads": sum(downloads[root] for root in roots),
                "projects": len(roots),
                "scope": scope_reason(candidate, scope),
            }
        )
    return rows


def history_rows(served, limit):
    picks = load_version_survey("history_picks.json")
    downloads = load_version_survey("downloads_by_version.json")
    total = sum(sum(versions.values()) for versions in downloads.values())
    rows = []
    for attr, pick in picks.items():
        project = norm(pick["project"])
        for version, meta in pick["versions"].items():
            if version in served.get(project, []):
                continue
            rows.append(
                {
                    "attr": attr,
                    "package": project,
                    "version": version,
                    "downloads": meta["downloads"],
                    "share": meta["downloads"] / total,
                    "projectShare": meta["share"],
                    "native": meta["native"],
                    "why": meta["why"],
                }
            )
    return sorted(
        rows, key=lambda row: (-row["downloads"], row["package"], row["version"])
    )[:limit]


def report(served, cutoff, limit):
    top = load("top.json")["rows"]
    classified = load("classified.json")
    graph = load("dependencies.json")
    optional = set(load("native_optional.json"))
    scope = load("out-of-scope.json")
    shipped = set(served)
    downloads = {norm(row["project"]): row["download_count"] for row in top}
    roots = [
        norm(row["project"])
        for row in top
        if classified.get(norm(row["project"]), {}).get("rank", cutoff + 1) <= cutoff
    ]

    buildable, scoped, blocked, unknown = [], {}, {}, {}
    for root in roots:
        blockers, missing = closure_blockers(root, graph, classified, optional, shipped)
        if missing:
            unknown[root] = sorted(missing)
            continue
        reasons = sorted(
            {
                scope_reason(package, scope)
                for package in blockers
                if scope_reason(package, scope)
            }
        )
        if reasons:
            scoped[root] = reasons
        elif blockers:
            blocked[root] = blockers
        else:
            buildable.append(root)

    pure = [
        {
            "package": root,
            "downloads": downloads[root],
            "share": downloads[root] / sum(downloads.values()),
        }
        for root in buildable
        if root not in shipped and classified[root].get("final") == "pure"
    ]
    pure.sort(key=lambda row: (-row["downloads"], row["package"]))
    return {
        "cutoff": cutoff,
        "survey": {
            "projects": len(roots),
            "downloads": sum(downloads[root] for root in roots),
        },
        "coverage": {
            "buildable": len(buildable),
            "blocked": len(blocked),
            "outOfScope": len(scoped),
            "unknown": len(unknown),
        },
        "publish": pure[:limit],
        "native": rank_native(blocked, downloads, scope, limit),
        "history": history_rows(served, limit),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("wheel_versions")
    parser.add_argument("--cutoff", type=int, choices=(100, 1000, 10000), default=10000)
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()
    with open(args.wheel_versions) as f:
        served = {norm(name): versions for name, versions in json.load(f).items()}
    json.dump(
        report(served, args.cutoff, args.limit), sys.stdout, separators=(",", ":")
    )


if __name__ == "__main__":
    main()
