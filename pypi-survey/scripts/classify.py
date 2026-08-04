#!/usr/bin/env python3
"""Classify cached packages as pure / native / sdist-only / no-files.

Wheel filename: name-ver(-build)?-pytag-abitag-plattag.whl
plattag != 'any' anywhere -> native. All wheels 'any' -> pure.
Only sdist -> sdist_only (refined separately by scanning the sdist).
"""

import json
import os
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(BASE, "cache")


def norm(name: str) -> str:
    return name.lower().replace("_", "-").replace(".", "-")


def wheel_tags(filename: str):
    """Return (pytags, abitags, plattags) from a wheel filename."""
    stem = filename[: -len(".whl")]
    parts = stem.split("-")
    # last three dash-separated fields are py-abi-plat (each may be dotted)
    py, abi, plat = parts[-3], parts[-2], parts[-1]
    return py.split("."), abi.split("."), plat.split(".")


def classify(rec):
    files = [f for f in rec.get("files") or [] if not f.get("yanked")] or (
        rec.get("files") or []
    )
    if rec.get("error"):
        return "error", {}
    if not files:
        return "no_files", {}
    wheels = [f for f in files if f["packagetype"] == "bdist_wheel"]
    sdists = [f for f in files if f["packagetype"] == "sdist"]
    if not wheels:
        return "sdist_only", {
            "sdist_url": sdists[0]["url"] if sdists else None,
            "sdist_size": sdists[0].get("size") if sdists else None,
        }
    plats, abis = set(), set()
    for w in wheels:
        try:
            _, abi, plat = wheel_tags(w["filename"])
        except Exception:
            continue
        plats.update(plat)
        abis.update(abi)
    if plats == {"any"}:
        return "pure", {}
    return "native", {
        "abis": sorted(abis),
        "plats": sorted(plats),
        "n_wheels": len(wheels),
    }


def main():
    with open(os.path.join(BASE, "top.json")) as f:
        top = json.load(f)
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
    names = [r["project"] for r in top["rows"]][:n]

    out = {}
    missing = 0
    for i, name in enumerate(names):
        path = os.path.join(CACHE, norm(name) + ".json")
        if not os.path.exists(path):
            missing += 1
            continue
        with open(path) as f:
            rec = json.load(f)
        cls, extra = classify(rec)
        out[norm(name)] = {"rank": i + 1, "name": name, "class": cls, **extra}

    with open(os.path.join(BASE, "classified.json"), "w") as f:
        json.dump(out, f, indent=1)

    for cutoff in (100, 1000, 10000):
        subset = [v for v in out.values() if v["rank"] <= cutoff]
        counts = {}
        for v in subset:
            counts[v["class"]] = counts.get(v["class"], 0) + 1
        print(f"top {cutoff}: total={len(subset)} {counts}")
    if missing:
        print(f"missing from cache: {missing}")


if __name__ == "__main__":
    main()
