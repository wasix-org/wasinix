"""Part C: for each in-use historical version, package it or point it at the latest.

Combines install volume, the API diff against the current latest, the ecosystem's
own version caps, and the pure/native build cost.
"""

import gzip, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE, DATA = f"{HERE}/../cache", f"{HERE}/../data"

MIN_SHARE = 0.02


def verdict(d):
    """How safe is it to serve `latest` to something that asked for this version?"""
    if not d.get("analysable"):
        return "unknown"
    if d["removed_root"] > 0:
        return "breaking"
    tol = max(2, int(0.005 * d["n_old"]))
    if d["removed"] == 0 and d["narrowed"] == 0:
        return "safe"
    if d["removed"] <= tol and d["narrowed"] <= tol:
        return "probably-safe"
    return "breaking"


def main():
    usage = json.load(open(f"{DATA}/usage.json"))
    caps = json.load(open(f"{DATA}/caps.json"))
    diffs = json.load(open(f"{DATA}/api_diff.json"))
    scheme = json.load(open(f"{DATA}/scheme.json"))

    rows = []
    for p, u in usage.items():
        d = {e["v"]: e for e in diffs.get(p, {}).get("diffs", [])}
        cap = caps.get(p, {})
        hard = cap.get("resolves_to", {})
        with gzip.open(f"{CACHE}/{p}.json.gz", "rt") as fh:
            rel = json.load(fh)["rel"]
        for tv in u["top_versions"]:
            v = tv["v"]
            if v == u["latest"] or tv["share"] < MIN_SHARE:
                continue
            e = d.get(v)
            ver = verdict(e) if e else "unmeasured"
            rows.append(
                {
                    "project": p,
                    "rank": u["rank"],
                    "version": v,
                    "latest": u["latest"],
                    "downloads": tv["c"],
                    "share": tv["share"],
                    "age_days": tv["age_days"],
                    "native": tv["native"],
                    "boundary": e["boundary"] if e else None,
                    "removed_root": e.get("removed_root") if e else None,
                    "removed": e.get("removed") if e else None,
                    "narrowed": e.get("narrowed") if e else None,
                    "examples": (e.get("examples_root") or e.get("examples") or [])[:6]
                    if e
                    else [],
                    "verdict": ver,
                    "scheme": scheme.get(p, {}).get("scheme"),
                    # dependents whose own metadata forbids the latest and lands here
                    "pinned_dependents": hard.get(v, 0),
                }
            )

    rows.sort(key=lambda r: -r["downloads"])
    json.dump(rows, open(f"{DATA}/recommend.json", "w"))

    tot = sum(u["covered"] for u in usage.values())
    nonlatest = sum(u["covered"] * (1 - u["latest_share"]) for u in usage.values())
    by = {}
    for r in rows:
        by[r["verdict"]] = by.get(r["verdict"], 0) + r["downloads"]
    print(
        f"{len(rows)} (project, version) pairs above {MIN_SHARE:.0%} share",
        file=sys.stderr,
    )
    print(
        f"they carry {sum(r['downloads'] for r in rows) / tot:.1%} of all installs "
        f"({sum(r['downloads'] for r in rows) / nonlatest:.1%} of non-latest installs)",
        file=sys.stderr,
    )
    for k, v in sorted(by.items(), key=lambda kv: -kv[1]):
        print(f"  {k:14s} {v / sum(by.values()):6.1%}", file=sys.stderr)


if __name__ == "__main__":
    main()
