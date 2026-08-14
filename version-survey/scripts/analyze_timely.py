"""Was the installed release the newest one available *on the day it was installed*?

The plain latest-share metric punishes fast-moving projects: boto3 ships daily, so its
current release has one day of traffic inside a 30-day window. This recomputes the same
question against the release that was newest on each day.
"""

import gzip, json, os, sys
from datetime import datetime, timezone
from packaging.version import Version, InvalidVersion

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ch import query

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE, DATA = f"{HERE}/../cache", f"{HERE}/../data"
meta = json.load(open(f"{DATA}/top.json"))
START, END = meta["start"], meta["end"]
INSTALLERS = "('pip','uv','poetry','pdm','pex','Bazel')"


def pv(s):
    try:
        return Version(s)
    except InvalidVersion:
        return None


def timeline(project):
    """[(date, latest Version as of that date)] plus a canonical-version lookup."""
    with gzip.open(f"{CACHE}/{project}.json.gz", "rt") as fh:
        rel = json.load(fh)["rel"]
    rec, any_rec = [], []
    for v, e in rel.items():
        x = pv(v)
        if x is None or e["y"] or not e["t"]:
            continue
        any_rec.append((e["t"][:10], x))
        if not x.is_prerelease:
            rec.append((e["t"][:10], x))
    # a few projects (opentelemetry-semantic-conventions) only ever ship prereleases
    out = rec or any_rec
    out.sort()
    return out


def main():
    top = [r["project"] for r in json.load(open(f"{DATA}/top.json"))["rows"]]
    tot = on_latest = on_major = dropped = 0
    per = {}
    BATCH = 150
    for i in range(0, len(top), BATCH):
        chunk = top[i : i + BATCH]
        names = "(" + ",".join("'" + p.replace("'", "\\'") + "'" for p in chunk) + ")"
        # The endpoint also truncates on the way out, non-deterministically, at a few
        # hundred thousand rows, so page through an explicit ORDER BY instead.
        base = f"""
        SELECT project, version, toString(date), sum(count) AS c
        FROM pypi.pypi_downloads_per_day_by_version_by_installer_by_type
        WHERE date >= '{START}' AND date <= '{END}' AND installer IN {INSTALLERS}
          AND project IN {names}
        GROUP BY project, version, date
        HAVING c >= 20
        ORDER BY project, version, date"""
        rows, off, PAGE = [], 0, 60000
        while True:
            page = query(base + f" LIMIT {PAGE} OFFSET {off}")
            rows += page
            if len(page) < PAGE:
                break
            off += PAGE
        tl = {p: timeline(p) for p in chunk}
        cache = {}
        for project, version, date, c in rows:
            c = int(c)
            x = pv(version)
            if x is None:
                dropped += c
                continue
            key = (project, date)
            best = cache.get(key)
            if best is None:
                best = None
                for d, v in tl[project]:
                    if d <= date:
                        if best is None or v > best:
                            best = v
                    else:
                        break
                cache[key] = best
            if best is None:
                dropped += c
                continue
            a = per.setdefault(project, [0, 0, 0])
            a[0] += c
            tot += c
            if x == best:
                a[1] += c
                on_latest += c
            if x.release and best.release and x.release[0] == best.release[0]:
                a[2] += c
                on_major += c
        print(
            f"  {min(i + BATCH, len(top))}/{len(top)}  running latest-of-the-day share "
            f"{on_latest / max(tot, 1):.1%}",
            file=sys.stderr,
        )

    out = {
        "covered": tot,
        "dropped": dropped,
        "latest_of_the_day_share": on_latest / tot,
        "same_major_share": on_major / tot,
        "per_project": {
            p: {"covered": a[0], "latest": a[1] / a[0], "major": a[2] / a[0]}
            for p, a in per.items()
            if a[0]
        },
    }
    json.dump(out, open(f"{DATA}/timely.json", "w"))
    print(f"dropped {dropped:,}", file=sys.stderr)
    print(
        f"{tot:,} downloads; newest-on-the-day {out['latest_of_the_day_share']:.1%}; "
        f"same major {out['same_major_share']:.1%}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
