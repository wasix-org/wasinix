#!/usr/bin/env python3
"""Transitive analysis: does each package's runtime dep closure contain native code?

Env: CPython 3.12, linux, x86_64, no extras.
Fetches metadata for closure packages outside the top-10k cache.
Writes transitive.json: {pkg: {"self": cls, "closure": "native"|"pure"|"unknown",
                               "native_deps": [...], "unknown_deps": [...]}}
"""

import json
import os
import sys
from concurrent.futures import ThreadPoolExecutor

from packaging.requirements import Requirement, InvalidRequirement

import fetch_meta
import classify as classify_mod

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
CACHE = os.path.join(ROOT, "cache")

ENV = {
    "python_version": "3.12",
    "python_full_version": "3.12.8",
    "sys_platform": "linux",
    "platform_system": "Linux",
    "platform_machine": "x86_64",
    "platform_release": "6.0",
    "platform_version": "#1",
    "os_name": "posix",
    "implementation_name": "cpython",
    "implementation_version": "3.12.8",
    "platform_python_implementation": "CPython",
    "extra": "",
}

norm = fetch_meta.norm


def load(key):
    path = os.path.join(CACHE, key + ".json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


def deps_of(rec):
    out = set()
    for r in rec.get("requires_dist") or []:
        try:
            req = Requirement(r)
        except InvalidRequirement:
            continue
        if req.marker is not None:
            try:
                if not req.marker.evaluate(ENV):
                    continue
            except Exception:
                pass  # keep on marker eval failure (conservative)
        out.add(norm(req.name))
    return out


def main():
    with open(os.path.join(DATA, "classified.json")) as f:
        classified = json.load(f)
    # refined classes for sdist_only packages, if the scan has run
    refined = {}
    refpath = os.path.join(DATA, "sdist_refined.json")
    if os.path.exists(refpath):
        with open(refpath) as f:
            refined = json.load(f)

    def cls_of(key, rec):
        c = classified.get(key, {}).get("class")
        if c is None:
            c, _ = classify_mod.classify(rec)
        if c == "sdist_only" and key in refined:
            c = refined[key]
        return c

    # BFS closure, fetching missing metadata as needed
    known = {}  # key -> {"cls": ..., "deps": set()}
    frontier = list(classified.keys())
    while frontier:
        missing = [k for k in frontier if load(k) is None]
        if missing:
            print(f"fetching {len(missing)} out-of-top10k packages", flush=True)
            with ThreadPoolExecutor(max_workers=24) as ex:
                list(ex.map(fetch_meta.fetch, missing))
        nxt = []
        for k in frontier:
            if k in known:
                continue
            rec = load(k)
            if rec is None or rec.get("error"):
                known[k] = {"cls": "error", "deps": set()}
                continue
            d = deps_of(rec)
            known[k] = {"cls": cls_of(k, rec), "deps": d}
            nxt.extend(x for x in d if x not in known)
        frontier = list(set(nxt))

    print(f"graph: {len(known)} packages")

    # propagate 'closure contains native' via SCC condensation (iterative Tarjan)
    index = {}
    lowlink = {}
    onstack = set()
    stack = []
    scc_of = {}
    sccs = []
    counter = [0]

    for root in known:
        if root in index:
            continue
        work = [(root, iter(sorted(known[root]["deps"] & known.keys())))]
        index[root] = lowlink[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        onstack.add(root)
        while work:
            v, it = work[-1]
            advanced = False
            for w in it:
                if w not in known:
                    continue
                if w not in index:
                    index[w] = lowlink[w] = counter[0]
                    counter[0] += 1
                    stack.append(w)
                    onstack.add(w)
                    work.append((w, iter(sorted(known[w]["deps"] & known.keys()))))
                    advanced = True
                    break
                elif w in onstack:
                    lowlink[v] = min(lowlink[v], index[w])
            if advanced:
                continue
            work.pop()
            if work:
                pv = work[-1][0]
                lowlink[pv] = min(lowlink[pv], lowlink[v])
            if lowlink[v] == index[v]:
                comp = []
                while True:
                    w = stack.pop()
                    onstack.discard(w)
                    comp.append(w)
                    scc_of[w] = len(sccs)
                    if w == v:
                        break
                sccs.append(comp)

    # reverse topological order = order sccs were completed (Tarjan property)
    scc_native = [False] * len(sccs)
    scc_unknown = [False] * len(sccs)
    for i, comp in enumerate(sccs):
        nat = any(known[m]["cls"] == "native" for m in comp)
        unk = any(known[m]["cls"] in ("sdist_only", "error", "no_files") for m in comp)
        for m in comp:
            for d in known[m]["deps"]:
                if d in scc_of and scc_of[d] != i:
                    nat = nat or scc_native[scc_of[d]]
                    unk = unk or scc_unknown[scc_of[d]]
        scc_native[i] = nat
        scc_unknown[i] = unk

    # per-package direct native deps list (for reporting common culprits)
    out = {}
    for k, meta in classified.items():
        if k not in known:
            continue
        info = known[k]
        closure_native = scc_native[scc_of[k]]
        closure_unknown = scc_unknown[scc_of[k]]
        self_cls = info["cls"]
        if self_cls == "native":
            verdict = "native_self"
        elif closure_native:
            verdict = "native_deps"
        elif closure_unknown:
            verdict = "unknown"
        else:
            verdict = "pure_closure"
        nat_direct = sorted(
            d for d in info["deps"] if d in known and known[d]["cls"] == "native"
        )
        out[k] = {
            "rank": meta["rank"],
            "self": self_cls,
            "verdict": verdict,
            "native_direct": nat_direct,
        }

    with open(os.path.join(DATA, "transitive.json"), "w") as f:
        json.dump(out, f, indent=1)

    with open(os.path.join(DATA, "dependencies.json"), "w") as f:
        json.dump(
            {key: sorted(value["deps"]) for key, value in sorted(known.items())},
            f,
            separators=(",", ":"),
        )

    for cutoff in (100, 1000, 10000):
        subset = [v for v in out.values() if v["rank"] <= cutoff]
        counts = {}
        for v in subset:
            counts[v["verdict"]] = counts.get(v["verdict"], 0) + 1
        print(f"top {cutoff}: {dict(sorted(counts.items()))}")


if __name__ == "__main__":
    main()
