"""Build findings.md and the aggregates the HTML page embeds."""

import json, os, sys
from packaging.version import Version, InvalidVersion

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = f"{HERE}/../data"
OUT = f"{HERE}/.."

usage = json.load(open(f"{DATA}/usage.json"))
caps = json.load(open(f"{DATA}/caps.json"))
scheme = json.load(open(f"{DATA}/scheme.json"))
diffs = json.load(open(f"{DATA}/api_diff.json"))
recs = json.load(open(f"{DATA}/recommend.json"))
pysplit = json.load(open(f"{DATA}/python_split.json"))
meta = json.load(open(f"{DATA}/top.json"))
timely = json.load(open(f"{DATA}/timely.json"))

TOT = sum(u["covered"] for u in usage.values())
P = {}  # everything the HTML page needs


def pct(x):
    return f"{x * 100:.1f}%"


def wavg(key):
    return sum(u[key] * u["covered"] for u in usage.values()) / TOT


def quantiles(vals, qs=(0.1, 0.25, 0.5, 0.75, 0.9)):
    v = sorted(vals)
    return {f"p{int(q * 100)}": v[min(int(q * len(v)), len(v) - 1)] for q in qs}


# ---------------------------------------------------------------- part A
A = {
    "n_projects": len(usage),
    "downloads": TOT,
    "window": [meta["start"], meta["end"]],
    "latest_share": wavg("latest_share"),
    "same_major_share": wavg("same_major_share"),
    "same_minor_share": wavg("same_minor_share"),
    "prerelease_share": wavg("prerelease_share"),
    "latest_share_q": quantiles([u["latest_share"] for u in usage.values()]),
    "n90_q": quantiles([u["n90"] for u in usage.values() if u["n90"]]),
    "installed_age_q": quantiles(
        [
            u["median_installed_age_days"]
            for u in usage.values()
            if u["median_installed_age_days"] is not None
        ]
    ),
}
A["timely_latest_share"] = timely["latest_of_the_day_share"]
A["timely_same_major_share"] = timely["same_major_share"]
A["timely_covered"] = timely["covered"]
A["coverage_curve"] = [
    {
        "k": k,
        "share": sum(
            sum(tv["c"] for tv in u["top_versions"][:k]) for u in usage.values()
        )
        / TOT,
    }
    for k in (1, 2, 3, 5, 8, 12, 20, 25)
]

nonlatest = TOT * (1 - A["latest_share"])
in_major = sum(
    u["covered"] * (u["same_major_share"] - u["latest_share"]) for u in usage.values()
)
A["nonlatest_within_major"] = in_major / nonlatest
A["nonlatest_older_major"] = 1 - in_major / nonlatest

buckets = {"lt6m": 0, "6m_2y": 0, "gt2y": 0}
for u in usage.values():
    for tv in u["top_versions"]:
        if tv["v"] == u["latest"] or tv["share"] < 0.02 or tv["age_days"] is None:
            continue
        k = (
            "lt6m"
            if tv["age_days"] <= 180
            else ("6m_2y" if tv["age_days"] <= 730 else "gt2y")
        )
        buckets[k] += tv["c"]
A["age_buckets"] = buckets


# interpreter generation behind each version
def canon(s):
    try:
        return str(Version(s))
    except InvalidVersion:
        return None


mod_lat = leg_lat = mod_old = leg_old = 0
for p, u in usage.items():
    sp = {}
    for v, (m, l, _) in pysplit.get(p, {}).items():
        k = canon(v)
        if k:
            a = sp.setdefault(k, [0, 0])
            a[0] += m
            a[1] += l
    for tv in u["top_versions"]:
        m, l = sp.get(tv["v"], (0, 0))
        if tv["v"] == u["latest"]:
            mod_lat += m
            leg_lat += l
        else:
            mod_old += m
            leg_old += l
A["python_modern_latest"] = mod_lat / max(mod_lat + leg_lat, 1)
A["python_modern_old"] = mod_old / max(mod_old + leg_old, 1)

# projects with a live older major line
live_majors = []
for p, u in usage.items():
    head = u["latest"].split(".")[0]
    if not head.isdigit():
        continue
    off = sum(c for k, c in u["by_major"].items() if k != head)
    if off / u["covered"] >= 0.10 and u["covered"] > 1e8:
        live_majors.append(
            {
                "project": p,
                "latest": u["latest"],
                "off_major": off / u["covered"],
                "downloads": u["covered"],
                "native": u["latest_native"],
                "majors": {
                    k: c / u["covered"] for k, c in list(u["by_major"].items())[:5]
                },
            }
        )
live_majors.sort(key=lambda r: -r["downloads"])
A["live_major_lines"] = live_majors

# ---------------------------------------------------------------- part B
B = {}
sch = {}
for p, s in scheme.items():
    a = sch.setdefault(
        s["scheme"],
        {
            "n": 0,
            "traffic": 0,
            "latest": 0,
            "in_major": 0,
            "dependents": 0,
            "capped": 0,
            "cap_excl": 0,
        },
    )
    u = usage[p]
    a["n"] += 1
    a["traffic"] += u["covered"]
    a["latest"] += u["covered"] * u["latest_share"]
    a["in_major"] += u["covered"] * u["same_major_share"]
    c = caps.get(p)
    if c and c["dependents"]:
        a["dependents"] += c["dependents"]
        a["capped"] += c["pct_capped"] * c["dependents"]
        a["cap_excl"] += c["excludes_latest_by_cap"]
for a in sch.values():
    a["latest"] /= a["traffic"]
    a["in_major"] /= a["traffic"]
    a["traffic_share"] = a["traffic"] / TOT
    if a["dependents"]:
        a["capped"] /= a["dependents"]
        a["cap_excl"] /= a["dependents"]
B["schemes"] = sch
B["major_bumps_per_year_q"] = quantiles(
    [s["major_bumps_per_year"] for s in scheme.values()]
)
B["never_bumped_major"] = sum(
    1 for s in scheme.values() if s["n_majors"] == 1 and s["scheme"] == "semver-shaped"
)
B["semver_shaped_n"] = sum(1 for s in scheme.values() if s["scheme"] == "semver-shaped")

dtot = sum(c["dependents"] for c in caps.values())
B["dep_total"] = dtot
B["dep_capped"] = sum(c["pct_capped"] * c["dependents"] for c in caps.values()) / dtot
B["dep_pinned"] = sum(c["pct_pinned"] * c["dependents"] for c in caps.values()) / dtot
B["dep_excl_latest"] = sum(c["excludes_latest"] for c in caps.values()) / dtot
B["dep_excl_by_cap"] = sum(c["excludes_latest_by_cap"] for c in caps.values()) / dtot
B["dep_excl_by_pin"] = sum(c["excludes_latest_by_pin"] for c in caps.values()) / dtot

# empirical breakage by boundary type
bnd = {}
for p, d in diffs.items():
    for e in d["diffs"]:
        if not e.get("analysable"):
            continue
        a = bnd.setdefault(
            e["boundary"],
            {
                "n": 0,
                "broke": 0,
                "root_broke": 0,
                "traffic": 0,
                "broke_traffic": 0,
                "root_broke_traffic": 0,
            },
        )
        share = e.get("share") or 0
        vol = usage[p]["covered"] * share
        a["n"] += 1
        a["traffic"] += vol
        if e["removed"] or e["narrowed"]:
            a["broke"] += 1
            a["broke_traffic"] += vol
        if e["removed_root"]:
            a["root_broke"] += 1
            a["root_broke_traffic"] += vol
B["boundaries"] = bnd

# per-project semver honesty: breakage seen at non-major boundaries
honesty = []
for p, d in diffs.items():
    sub = [
        e
        for e in d["diffs"]
        if e.get("analysable") and e["boundary"] in ("minor", "patch")
    ]
    if not sub:
        continue
    bad = [e for e in sub if e["removed_root"] > 0]
    honesty.append(
        {
            "project": p,
            "rank": d["rank"],
            "latest": d["latest"],
            "n": len(sub),
            "bad": len(bad),
            "worst": max((e["removed_root"] for e in sub), default=0),
            "examples": (bad[0]["examples_root"][:5] if bad else []),
            "downloads": usage[p]["covered"],
        }
    )
B["honesty"] = sorted(honesty, key=lambda r: (-r["worst"], -r["downloads"]))

B["top_capped"] = sorted(
    [{"project": k, **v} for k, v in caps.items() if v["dependents"] >= 300],
    key=lambda r: -r["pct_excludes_latest_by_cap"],
)[:30]

# ---------------------------------------------------------------- part C
C = {}
vd = {}
for r in recs:
    a = vd.setdefault(r["verdict"], {"n": 0, "downloads": 0})
    a["n"] += 1
    a["downloads"] += r["downloads"]
C["verdicts"] = vd
C["rec_downloads"] = sum(r["downloads"] for r in recs)
C["rec_share_all"] = C["rec_downloads"] / TOT
C["package_list"] = [r for r in recs if r["verdict"] in ("breaking", "unknown")][:80]
C["alias_list"] = [r for r in recs if r["verdict"] in ("safe", "probably-safe")][:40]
C["n_pairs"] = len(recs)

native_break = sum(
    r["downloads"] for r in recs if r["verdict"] == "breaking" and r["native"]
)
C["breaking_native_share"] = native_break / max(
    vd.get("breaking", {}).get("downloads", 1), 1
)

# what each packaging policy costs in builds and buys in coverage
policies = []
for k in (1, 2, 3, 5, 8):
    served = sum(sum(tv["c"] for tv in u["top_versions"][:k]) for u in usage.values())
    policies.append(
        {
            "name": f"top {k} version{'s' if k > 1 else ''} of every project",
            "builds": k * len(usage),
            "served": served / TOT,
            "exact": True,
        }
    )
for thr in (0.05, 0.02, 0.01):
    n = served = 0
    for u in usage.values():
        for m, c in u["by_major"].items():
            if c / u["covered"] >= thr:
                n += 1
                served += c
    policies.append(
        {
            "name": f"head of every major line above {thr:.0%} share",
            "builds": n,
            "served": served / TOT,
            "exact": False,
        }
    )
C["policies"] = policies

# how safe the "substitute within the major line" assumption actually is
same_major = {"traffic": 0, "root_broke_traffic": 0, "n": 0, "root_broke": 0}
for k in ("minor", "patch"):
    v = B["boundaries"].get(k)
    if v:
        for f in same_major:
            same_major[f] += v[f]
C["within_line_break_traffic"] = (
    same_major["root_broke_traffic"] / same_major["traffic"]
    if same_major["traffic"]
    else None
)
C["within_line_break_pairs"] = (
    same_major["root_broke"] / same_major["n"] if same_major["n"] else None
)

json.dump({"A": A, "B": B, "C": C, "meta": meta}, open(f"{DATA}/page_data.json", "w"))
print("wrote page_data.json", file=sys.stderr)
