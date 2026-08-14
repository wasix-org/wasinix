"""Pick the historical wheel versions wasinix should keep rebuildable.

Survey verdicts compare each in-use version against PyPI's latest; a registry
cares about the version it actually ships, so this re-diffs the candidates
against that and folds each breaking line down to its head.

  select_history.py jobs <wheel-versions.json>   # emit wheels to introspect
  select_history.py pick <wheel-versions.json>   # emit the selection
"""

import gzip, json, os, re, sys
from packaging.version import Version, InvalidVersion

HERE = os.path.dirname(os.path.abspath(__file__))
DATA, CACHE = f"{HERE}/../data", f"{HERE}/../cache"
APIDIR = f"{CACHE}/api"

MIN_SHARE = 0.02
PIN_FLOOR = 200  # dependents whose constraints resolve to exactly this version
MAJOR_SHARE = 0.05  # traffic a major line needs before it earns its own build
PER_ATTR = 4


def norm(s):
    return re.sub(r"[-_.]+", "-", s).lower()


def pv(s):
    try:
        return Version(s)
    except InvalidVersion:
        return None


def load_api(project, version):
    p = f"{APIDIR}/{project}@{version.replace('/', '_')}.json.gz"
    if not os.path.exists(p):
        return None
    with gzip.open(p, "rt") as fh:
        d = json.load(fh)
    return None if "error" in d else d


def diff(old, new):
    """(root removals, all removals, narrowed) going from old to new."""
    gone_root = sorted(set(old["root"]) - set(new["root"]))
    gone = sorted(set(old["api"]) - set(new["api"]))
    narrowed = 0
    for k, s in old["api"].items():
        n = new["api"].get(k)
        if s and n:
            a = [x for x in s.split("|")[0].split(",") if x]
            b = {x for x in n.split("|")[0].split(",") if x}
            if set(a) - b:
                narrowed += 1
    return gone_root, gone, narrowed


def breaks(old, new):
    gone_root, gone, narrowed = diff(old, new)
    tol = max(2, int(0.005 * len(old["api"])))
    return (
        bool(gone_root) or len(gone) > tol or narrowed > tol,
        gone_root,
        gone,
        narrowed,
    )


def candidates(shipped):
    """{attr: {version: row}} for in-use versions older than what we ship."""
    usage = json.load(open(f"{DATA}/usage.json"))
    caps = json.load(open(f"{DATA}/caps.json"))
    recs = {
        (r["project"], r["version"]): r
        for r in json.load(open(f"{DATA}/recommend.json"))
    }
    by_norm = {norm(a): a for a in shipped}
    out = {}
    for project, u in usage.items():
        attr = by_norm.get(norm(project))
        if attr is None:
            continue
        cur = pv(shipped[attr])
        if cur is None:
            continue
        pins = caps.get(project, {}).get("resolves_to", {})
        for tv in u["top_versions"]:
            v = pv(tv["v"])
            if v is None or v >= cur or v.is_prerelease:
                continue
            pinned = pins.get(tv["v"], 0)
            if tv["share"] < MIN_SHARE and pinned < PIN_FLOOR:
                continue
            out.setdefault(attr, {})[tv["v"]] = {
                "project": project,
                "share": tv["share"],
                "downloads": tv["c"],
                "age_days": tv["age_days"],
                "native": tv["native"],
                "pinned": pinned,
                "verdict_vs_pypi_latest": recs.get((project, tv["v"]), {}).get(
                    "verdict"
                ),
            }
    return out


def cmd_jobs(shipped):
    """Wheel URLs for every candidate plus the version we ship."""
    cand = candidates(shipped)
    jobs, missing = [], []
    for attr, vs in cand.items():
        project = next(iter(vs.values()))["project"]
        with gzip.open(f"{CACHE}/{project}.json.gz", "rt") as fh:
            rel = json.load(fh)["rel"]
        canon = {}
        for raw, e in rel.items():
            x = pv(raw)
            if x is not None:
                canon[str(x)] = e
        for want in list(vs) + [shipped[attr]]:
            x = pv(want)
            e = canon.get(str(x)) if x else None
            if not e or not e.get("whl"):
                missing.append((attr, want))
                continue
            if (e["whl"][1] or 0) > 40 * 1024 * 1024:
                missing.append((attr, want))
                continue
            jobs.append([project, str(x), e["whl"][0]])
    seen, uniq = set(), []
    for j in jobs:
        k = (j[0], j[1])
        if k not in seen:
            seen.add(k)
            uniq.append(j)
    json.dump(uniq, open(f"{DATA}/history_jobs.json", "w"))
    print(
        f"{len(uniq)} wheels to introspect; {len(missing)} unavailable", file=sys.stderr
    )
    if missing:
        print(f"  {missing[:10]}", file=sys.stderr)


def line_of(v):
    r = v.release + (0,) * (2 - len(v.release))
    return f"{r[0]}.x" if r[0] else f"0.{r[1]}.x"


def cmd_pick(shipped):
    usage = json.load(open(f"{DATA}/usage.json"))
    all_shares = {
        p: {tv["v"]: tv["share"] for tv in u["top_versions"]} for p, u in usage.items()
    }
    cand = candidates(shipped)
    picked, notes = {}, []
    for attr in sorted(cand):
        vs = cand[attr]
        project = next(iter(vs.values()))["project"]
        cur = str(pv(shipped[attr]))
        new = load_api(project, cur)
        rows = []
        for v, meta in vs.items():
            cv = str(pv(v))
            old = load_api(project, cv)
            if old is None or new is None:
                rows.append(
                    {
                        **meta,
                        "v": v,
                        "state": "unmeasured",
                        "root": None,
                        "removed": None,
                        "narrowed": None,
                    }
                )
                continue
            bad, gone_root, gone, narrowed = breaks(old, new)
            rows.append(
                {
                    **meta,
                    "v": v,
                    "state": "breaking" if bad else "substitutable",
                    "root": len(gone_root),
                    "removed": len(gone),
                    "narrowed": narrowed,
                    "examples": gone_root[:6],
                }
            )
        keep = [r for r in rows if r["state"] != "substitutable"]
        if not keep:
            continue
        # Two reasons to build a version. A major line with real traffic gets its
        # head, per the retention policy; and any version enough published projects
        # resolve to gets itself, because nothing else can satisfy that constraint.
        # a 0.x project has no major line to speak of, so its compat line is the minor
        line_share = {}
        for v, share in all_shares.get(project, {}).items():
            x = pv(v)
            if x:
                line_share[line_of(x)] = line_share.get(line_of(x), 0) + share
        heads = {}
        for r in keep:
            ln = line_of(pv(r["v"]))
            if line_share.get(ln, 0) < MAJOR_SHARE:
                continue
            if ln not in heads or pv(r["v"]) > pv(heads[ln]["v"]):
                heads[ln] = r
        chosen = {}
        for ln, r in heads.items():
            chosen[r["v"]] = {
                **r,
                "why": f"head of the {ln} line ({line_share[ln]:.0%} of installs)",
            }
        for r in keep:
            if r["v"] not in chosen and r["pinned"] >= PIN_FLOOR:
                chosen[r["v"]] = {
                    **r,
                    "why": f"{r['pinned']} published projects resolve here",
                }
        if len(chosen) > PER_ATTR:
            top = sorted(
                chosen.values(), key=lambda r: -(r["pinned"] + r["share"] * 1000)
            )[:PER_ATTR]
            chosen = {r["v"]: r for r in top}
        if chosen:
            picked[attr] = {
                "project": project,
                "shipped": shipped[attr],
                "versions": dict(sorted(chosen.items(), key=lambda kv: pv(kv[0]))),
            }
    json.dump(picked, open(f"{DATA}/history_picks.json", "w"))
    n = sum(len(p["versions"]) for p in picked.values())
    print(f"{n} versions across {len(picked)} wheels", file=sys.stderr)


if __name__ == "__main__":
    cmd, path = sys.argv[1], sys.argv[2]
    shipped = json.load(open(path))
    {"jobs": cmd_jobs, "pick": cmd_pick}[cmd](shipped)
