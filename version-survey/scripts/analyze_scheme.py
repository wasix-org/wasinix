"""Part B: classify each project's versioning scheme and its major-bump cadence."""

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


def classify(vers, latest):
    """vers: sorted list of stable Versions."""
    rel = [v.release for v in vers]
    maj = latest.release[0]
    if maj >= 1900 or any(r[0] >= 1900 for r in rel[-10:]):
        return "calver"
    if maj == 0:
        return "zerover"
    n3 = sum(1 for r in rel if len(r) >= 3)
    if n3 / max(len(rel), 1) >= 0.6:
        return "semver-shaped"
    return "two-component"


def main():
    usage = json.load(open(f"{DATA}/usage.json"))
    out = {}
    for p, u in usage.items():
        with gzip.open(f"{CACHE}/{p}.json.gz", "rt") as fh:
            rel = json.load(fh)["rel"]
        recs = []
        for v, e in rel.items():
            x = pv(v)
            if x is None or x.is_prerelease or not e.get("t"):
                continue
            recs.append((x, datetime.fromisoformat(e["t"].replace("Z", "+00:00"))))
        recs.sort()
        if len(recs) < 2:
            continue
        vers = [x for x, _ in recs]
        latest = vers[-1]
        scheme = classify(vers, latest)

        majors, minors, patches, first_seen = 0, 0, 0, {}
        for i in range(1, len(vers)):
            a, b = vers[i - 1].release, vers[i].release
            a = a + (0,) * (3 - len(a))
            b = b + (0,) * (3 - len(b))
            if b[0] > a[0]:
                majors += 1
            elif b[0] == a[0] and b[1] > a[1]:
                minors += 1
            elif b[:2] == a[:2] and b[2] > a[2]:
                patches += 1
        for x, t in recs:
            first_seen.setdefault(x.release[0], t)

        span_days = (recs[-1][1] - recs[0][1]).days or 1
        first_release, last_release = recs[0][1], recs[-1][1]
        # age of the current major line
        cur_major_start = first_seen.get(latest.release[0])
        out[p] = {
            "rank": u["rank"],
            "scheme": scheme,
            "latest": str(latest),
            "n_stable": len(vers),
            "n_majors": len(first_seen),
            "majors": sorted(first_seen),
            "major_bumps": majors,
            "minor_bumps": minors,
            "patch_bumps": patches,
            "releases_per_year": len(vers) / (span_days / 365.25),
            "major_bumps_per_year": majors / (span_days / 365.25),
            "first_release": first_release.date().isoformat(),
            "last_release": last_release.date().isoformat(),
            "current_major_age_days": (END - cur_major_start).days
            if cur_major_start
            else None,
        }
    json.dump(out, open(f"{DATA}/scheme.json", "w"))
    print(f"{len(out)} projects", file=sys.stderr)


if __name__ == "__main__":
    main()
