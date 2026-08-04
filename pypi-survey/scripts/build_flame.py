#!/usr/bin/env python3
"""Build reverse-dependency flame data for native packages.

For each top-10k package T and each native package P in T's runtime dep
closure, emit the stack [P, d1, ..., T] along the (deterministic) shortest
path from T down to P. Merge stacks into a tree rooted at native packages.

Node weights: c = number of top-10k packages, d = sum of their 30-day downloads.

Outputs (into --out dir):
  flame_full.json   nested tree, unpruned
  flame_view.json   pruned tree for the HTML viewer
  reach.json        per-native-package reach stats
"""

import json
import os
import sys
from collections import deque

import fetch_meta
import classify as classify_mod
from transitive import deps_of, load as load_cache

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else BASE


def main():
    classified = json.load(open(os.path.join(BASE, "classified.json")))
    refined = json.load(open(os.path.join(BASE, "sdist_refined.json")))
    top = json.load(open(os.path.join(BASE, "top.json")))
    downloads = {
        fetch_meta.norm(r["project"]): r["download_count"] for r in top["rows"]
    }

    # full graph over everything in cache
    graph, cls = {}, {}
    for fn in os.listdir(os.path.join(BASE, "cache")):
        key = fn[:-5]
        rec = load_cache(key)
        if rec is None or rec.get("error"):
            cls[key] = "error"
            graph[key] = set()
            continue
        graph[key] = deps_of(rec)
        c = classified.get(key, {}).get("final")
        if c is None:
            c, _ = classify_mod.classify(rec)
            if c == "sdist_only":
                c = refined.get(key, "unknown")
        cls[key] = c

    roots = sorted(
        (k for k, v in classified.items() if v.get("final") in ("pure", "native")),
        key=lambda k: classified[k]["rank"],
    )
    print(f"graph={len(graph)} roots={len(roots)}")

    tree = {"name": "all native pulls", "c": 0, "d": 0, "ch": {}}
    reach = {}

    def add_stack(stack, dl):
        node = tree
        node["c"] += 1
        node["d"] += dl
        for name in stack:
            node = node["ch"].setdefault(name, {"name": name, "c": 0, "d": 0, "ch": {}})
            node["c"] += 1
            node["d"] += dl

    for T in roots:
        dl = downloads.get(T, 0)
        parent = {T: None}
        order = deque([T])
        while order:
            v = order.popleft()
            for w in sorted(graph.get(v, ())):
                if w not in parent and w in graph:
                    parent[w] = v
                    order.append(w)
        for P in parent:
            if cls.get(P) != "native":
                continue
            path = []
            x = P
            while x is not None:
                path.append(x)
                x = parent[x]
            add_stack(path, dl)  # path = [P, dependent, ..., T]
            r = reach.setdefault(P, {"pkgs": 0, "downloads": 0, "self": 0})
            if P == T:
                r["self"] = 1
            else:
                r["pkgs"] += 1
                r["downloads"] += dl

    # annotate reach with own rank/downloads
    for P, r in reach.items():
        r["rank"] = classified.get(P, {}).get("rank")
        r["own_downloads"] = downloads.get(P, 0)
    with open(os.path.join(OUT, "reach.json"), "w") as f:
        json.dump(
            dict(sorted(reach.items(), key=lambda kv: -kv[1]["pkgs"])), f, indent=1
        )

    def finalize(node):
        ch = sorted(node["ch"].values(), key=lambda n: -n["c"])
        node["ch"] = [finalize(c) for c in ch]
        return node

    def count(node):
        return 1 + sum(count(c) for c in node["ch"])

    finalize(tree)
    print("full tree nodes:", count(tree))
    with open(os.path.join(OUT, "flame_full.json"), "w") as f:
        json.dump(tree, f)

    # prune for the viewer: drop tiny frames into "(other)" buckets
    def prune(node, depth):
        keep, drop_c, drop_d = [], 0, 0
        for c in node["ch"]:
            if depth >= 24 or c["c"] < 2:
                drop_c += c["c"]
                drop_d += c["d"]
            else:
                keep.append(prune(c, depth + 1))
        if drop_c:
            keep.append({"name": "(other)", "c": drop_c, "d": drop_d, "ch": []})
        node["ch"] = keep
        return node

    view = prune(json.loads(json.dumps(tree)), 0)
    print("view tree nodes:", count(view))
    with open(os.path.join(OUT, "flame_view.json"), "w") as f:
        json.dump(view, f)


if __name__ == "__main__":
    main()
