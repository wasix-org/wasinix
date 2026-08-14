"""Pull 30-day per-version download counts for the top-N PyPI projects."""

import json, sys, os

sys.path.insert(0, os.path.dirname(__file__))
from ch import query

START, END = "2026-07-11", "2026-08-09"
# Real resolvers only: excludes bandersnatch mirrors, browser hits and caching proxies.
INSTALLERS = "('pip','uv','poetry','pdm','pex','Bazel')"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
OUT = os.path.join(os.path.dirname(__file__), "..", "data")

WINDOW = f"date >= '{START}' AND date <= '{END}' AND installer IN {INSTALLERS}"

print(f"top {N} projects, {START}..{END}", file=sys.stderr)
top = query(f"""
SELECT project, sum(count) AS c
FROM pypi.pypi_downloads_per_day_by_version_by_installer_by_type
WHERE {WINDOW}
GROUP BY project ORDER BY c DESC LIMIT {N}
""")
top = [
    {"rank": i + 1, "project": p, "downloads": int(c)} for i, (p, c) in enumerate(top)
]
json.dump(
    {"start": START, "end": END, "installers": INSTALLERS, "rows": top},
    open(f"{OUT}/top.json", "w"),
)
print(
    f"  {len(top)} projects, {sum(t['downloads'] for t in top):,} downloads",
    file=sys.stderr,
)

names = "(" + ",".join("'" + t["project"].replace("'", "\\'") + "'" for t in top) + ")"

print("per-version counts", file=sys.stderr)
rows = query(f"""
SELECT project, version, sum(count) AS c
FROM pypi.pypi_downloads_per_day_by_version_by_installer_by_type
WHERE {WINDOW} AND project IN {names}
GROUP BY project, version
HAVING c >= 200
ORDER BY project, c DESC
""")
byproj = {}
for p, v, c in rows:
    byproj.setdefault(p, {})[v] = int(c)
json.dump(byproj, open(f"{OUT}/downloads_by_version.json", "w"))
print(
    f"  {len(rows):,} (project,version) rows over {len(byproj)} projects",
    file=sys.stderr,
)

print("release upload times", file=sys.stderr)
# pypi.projects stores the raw metadata name; downloads use the PEP 503 normalized form.
NORM = "lower(replaceRegexpAll(name, '[-_.]+', '-'))"
rel = query(f"""
SELECT {NORM} AS n, version, min(upload_time) AS t, any(requires_python)
FROM pypi.projects
WHERE {NORM} IN {names}
GROUP BY n, version
ORDER BY n, t
""")
byrel = {}
for n, v, t, rp in rel:
    byrel.setdefault(n, {})[v] = {"uploaded": t, "requires_python": rp}
json.dump(byrel, open(f"{OUT}/releases.json", "w"))
print(f"  {len(rel):,} releases over {len(byrel)} projects", file=sys.stderr)
