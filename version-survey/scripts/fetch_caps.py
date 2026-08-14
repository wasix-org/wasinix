"""Pull every dependency requirement in the ecosystem that targets a surveyed project.

One row per (dependency, requirement string) with the number of distinct dependent
projects using it, taken from the latest release of each project active since 2024.
"""

import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ch import query

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = f"{HERE}/../data"

top = [r["project"] for r in json.load(open(f"{DATA}/top.json"))["rows"]]


def quote(ps):
    return "(" + ",".join("'" + p.replace("'", "\\'") + "'" for p in ps) + ")"


# Regex backslashes are doubled so the SQL string literal delivers a single one.
NORM = r"lower(replaceRegexpAll(name, '[-_.]+', '-'))"
SQL = r"""
WITH latest AS (
    SELECT {norm} AS proj,
           argMax(requires_dist, upload_time) AS rd,
           max(upload_time) AS t
    FROM pypi.projects
    GROUP BY proj
    HAVING t >= '2024-01-01'
)
SELECT dep, req, count() AS n
FROM (
    SELECT proj,
           -- drop environment markers and extras: only the version specifier matters here
           replaceRegexpAll(
             replaceRegexpAll(splitByChar(';', r)[1], '\\[[^\\]]*\\]', ''),
             '[[:space:]]+', '') AS req,
           lower(replaceRegexpAll(extract(r, '^[[:space:]]*([A-Za-z0-9._-]+)'), '[-_.]+', '-')) AS dep
    FROM latest ARRAY JOIN rd AS r
)
WHERE dep IN {names}
GROUP BY dep, req
ORDER BY dep, n DESC, req
"""

# The public endpoint caps a result at 100k rows, so walk the dependency list in batches.
rows = []
BATCH = 40
for i in range(0, len(top), BATCH):
    chunk = query(SQL.format(norm=NORM, names=quote(top[i : i + BATCH])))
    if len(chunk) >= 99000:
        print(
            f"  WARNING: batch at {i} may be truncated ({len(chunk)})", file=sys.stderr
        )
    rows += chunk
    print(
        f"  {min(i + BATCH, len(top))}/{len(top)} deps, {len(rows):,} rows",
        file=sys.stderr,
    )

out = {}
for dep, req, n in rows:
    out.setdefault(dep, []).append([req, int(n)])
json.dump(out, open(f"{DATA}/requirements.json", "w"))
print(
    f"{len(rows):,} distinct requirement strings over {len(out)} dependencies",
    file=sys.stderr,
)
