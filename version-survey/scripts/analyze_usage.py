"""Part A: how much of each project's install traffic goes to non-latest versions."""

import gzip, json, os, sys
from datetime import datetime, timezone
from packaging.version import Version, InvalidVersion

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE, DATA = f"{HERE}/../cache", f"{HERE}/../data"
END = datetime(2026, 8, 10, tzinfo=timezone.utc)


def pv(s):
    try:
        return Version(s)
    except InvalidVersion:
        return None


def load(p):
    with gzip.open(f"{CACHE}/{p}.json.gz", "rt") as fh:
        return json.load(fh)


def is_native(tags):
    """A release ships native code if any wheel targets a specific platform."""
    return any(not t.endswith("-any") for t in tags)


def main():
    top = json.load(open(f"{DATA}/top.json"))["rows"]
    dl = json.load(open(f"{DATA}/downloads_by_version.json"))
    out = {}
    for row in top:
        p, total = row["project"], row["downloads"]
        idx = load(p)
        rel = idx["rel"]
        # canonical version string -> release record
        canon = {}
        for v, e in rel.items():
            x = pv(v)
            if x is None:
                continue
            canon.setdefault(
                str(x),
                {
                    "t": e["t"],
                    "y": e["y"],
                    "tags": e["tags"],
                    "sdist": e["sdist"],
                    "raw": v,
                    "V": x,
                },
            )
        live = {
            k: e for k, e in canon.items() if not e["y"] and not e["V"].is_prerelease
        }
        if not live:
            live = {k: e for k, e in canon.items() if not e["V"].is_prerelease} or canon
        if not live:
            continue
        latest_k = max(live, key=lambda k: live[k]["V"])
        latest = live[latest_k]

        counts = {}
        unmatched = 0
        for v, c in dl.get(p, {}).items():
            x = pv(v)
            if x is None:
                unmatched += c
                continue
            counts[str(x)] = counts.get(str(x), 0) + c
        covered = sum(counts.values())
        if covered == 0:
            continue

        ranked = sorted(counts.items(), key=lambda kv: -kv[1])
        cum, n80, n90, n99 = 0, None, None, None
        for i, (_, c) in enumerate(ranked, 1):
            cum += c
            if n80 is None and cum >= 0.80 * covered:
                n80 = i
            if n90 is None and cum >= 0.90 * covered:
                n90 = i
            if n99 is None and cum >= 0.99 * covered:
                n99 = i

        lmaj = latest["V"].release[0] if latest["V"].release else 0
        lminor = latest["V"].release[:2]
        same_major = same_minor = prerel = 0
        age_w = []  # (age_days, count) of the release actually installed
        for k, c in counts.items():
            e = canon.get(k)
            x = pv(k)
            if x is None:
                continue
            if x.is_prerelease:
                prerel += c
            if x.release and x.release[0] == lmaj:
                same_major += c
                if x.release[:2] == lminor:
                    same_minor += c
            if e and e["t"]:
                t = datetime.fromisoformat(e["t"].replace("Z", "+00:00"))
                age_w.append(((END - t).days, c))
        age_w.sort()
        med_age = None
        if age_w:
            half, acc = sum(c for _, c in age_w) / 2, 0
            for a, c in age_w:
                acc += c
                if acc >= half:
                    med_age = a
                    break

        latest_c = counts.get(latest_k, 0)
        # major lines carrying real traffic
        by_major = {}
        for k, c in counts.items():
            x = pv(k)
            if x and x.release:
                by_major[x.release[0]] = by_major.get(x.release[0], 0) + c

        latest_age = None
        if latest["t"]:
            latest_age = (
                END - datetime.fromisoformat(latest["t"].replace("Z", "+00:00"))
            ).days

        out[p] = {
            "rank": row["rank"],
            "downloads": total,
            "covered": covered,
            "latest": latest_k,
            "latest_age_days": latest_age,
            "latest_native": is_native(latest["tags"]),
            "n_versions": len(canon),
            "n_versions_seen": len(counts),
            "latest_share": latest_c / covered,
            "same_major_share": same_major / covered,
            "same_minor_share": same_minor / covered,
            "prerelease_share": prerel / covered,
            "n80": n80,
            "n90": n90,
            "n99": n99,
            "median_installed_age_days": med_age,
            "by_major": {
                str(k): v for k, v in sorted(by_major.items(), key=lambda kv: -kv[1])
            },
            "top_versions": [
                {
                    "v": k,
                    "c": c,
                    "share": c / covered,
                    "age_days": (
                        END
                        - datetime.fromisoformat(canon[k]["t"].replace("Z", "+00:00"))
                    ).days
                    if canon.get(k) and canon[k]["t"]
                    else None,
                    "native": is_native(canon[k]["tags"]) if canon.get(k) else None,
                }
                for k, c in ranked[:25]
            ],
        }
    json.dump(out, open(f"{DATA}/usage.json", "w"))
    print(f"{len(out)} projects analysed", file=sys.stderr)


if __name__ == "__main__":
    main()
