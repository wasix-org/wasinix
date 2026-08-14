"""Part B/C: diff each in-use older version's public API against the current latest.

A removal tells you a consumer asking for the old version cannot simply be handed
the new one; a removal across a non-major boundary is a semver violation.
"""

import gzip, json, os, sys
from packaging.version import Version, InvalidVersion

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE, DATA = f"{HERE}/../cache", f"{HERE}/../data"
APIDIR = f"{CACHE}/api"


def load(project, version):
    p = f"{APIDIR}/{project}@{version.replace('/', '_')}.json.gz"
    if not os.path.exists(p):
        return None
    with gzip.open(p, "rt") as fh:
        d = json.load(fh)
    return None if "error" in d else d


def boundary(a, b):
    try:
        va, vb = Version(a), Version(b)
    except InvalidVersion:
        return "unknown"
    ra = va.release + (0,) * (3 - len(va.release))
    rb = vb.release + (0,) * (3 - len(vb.release))
    if ra[0] != rb[0]:
        return "major"
    if ra[1] != rb[1]:
        return "minor"
    if ra[2] != rb[2]:
        return "patch"
    return "same"


def params(sig):
    return [x for x in sig.split("|")[0].split(",") if x]


def main():
    targets = json.load(open(f"{DATA}/api_targets.json"))
    usage = json.load(open(f"{DATA}/usage.json"))
    out = {}
    for p, t in targets.items():
        new = load(p, t["latest"])
        if new is None:
            continue
        shares = {tv["v"]: tv["share"] for tv in usage[p]["top_versions"]}
        entries = []
        for v in t["versions"]:
            if v == t["latest"]:
                continue
            old = load(p, v)
            if old is None:
                continue
            if not old["api"] and not new["api"]:
                entries.append(
                    {
                        "v": v,
                        "boundary": boundary(v, t["latest"]),
                        "share": shares.get(v),
                        "analysable": False,
                        "reason": "no Python API in wheel (compiled only)",
                    }
                )
                continue
            gone_any = sorted(set(old["api"]) - set(new["api"]))
            gone_root = sorted(set(old["root"]) - set(new["root"]))
            narrowed = []
            for k, s in old["api"].items():
                if k in new["api"] and s and new["api"][k]:
                    lost = set(params(s)) - set(params(new["api"][k]))
                    if lost:
                        narrowed.append(k)
            shrank = len(new["api"]) < 0.5 * max(len(old["api"]), 1)
            ext_flip = (old["n_ext"] == 0) != (new["n_ext"] == 0)
            entries.append(
                {
                    "v": v,
                    "boundary": boundary(v, t["latest"]),
                    "share": shares.get(v),
                    "analysable": True,
                    "n_old": len(old["api"]),
                    "n_new": len(new["api"]),
                    "n_root_old": len(old["root"]),
                    "n_root_new": len(new["root"]),
                    "removed": len(gone_any),
                    "removed_root": len(gone_root),
                    "narrowed": len(narrowed),
                    "low_confidence": bool(shrank or ext_flip),
                    "examples_root": gone_root[:12],
                    "examples": gone_any[:12],
                }
            )
        if entries:
            out[p] = {"latest": t["latest"], "rank": usage[p]["rank"], "diffs": entries}
    json.dump(out, open(f"{DATA}/api_diff.json", "w"))
    print(
        f"{len(out)} projects, {sum(len(v['diffs']) for v in out.values())} diffs",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
