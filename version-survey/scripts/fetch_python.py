"""Which interpreter generation installs each version: modern (>=3.12) or legacy."""

import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ch import query

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = f"{HERE}/../data"
top = [r["project"] for r in json.load(open(f"{DATA}/top.json"))["rows"]]
meta = json.load(open(f"{DATA}/top.json"))
START, END = meta["start"], meta["end"]

out = {}
BATCH = 100
for i in range(0, len(top), BATCH):
    names = (
        "("
        + ",".join("'" + p.replace("'", "\\'") + "'" for p in top[i : i + BATCH])
        + ")"
    )
    rows = query(f"""
    SELECT project, version,
           sumIf(count, python_minor != '' AND splitByChar('.', python_minor)[1] = '3'
                        AND toInt32OrZero(splitByChar('.', python_minor)[2]) >= 12) AS modern,
           sumIf(count, python_minor != '' AND NOT (splitByChar('.', python_minor)[1] = '3'
                        AND toInt32OrZero(splitByChar('.', python_minor)[2]) >= 12)) AS legacy,
           sumIf(count, python_minor = '') AS unknown
    FROM pypi.pypi_downloads_per_day_by_version_by_python
    WHERE date >= '{START}' AND date <= '{END}' AND project IN {names}
    GROUP BY project, version
    HAVING modern + legacy + unknown >= 200
    """)
    for p, v, m, l, un in rows:
        out.setdefault(p, {})[v] = [int(m), int(l), int(un)]
    print(f"  {min(i + BATCH, len(top))}/{len(top)}", file=sys.stderr)

json.dump(out, open(f"{DATA}/python_split.json", "w"))
print(f"{sum(len(v) for v in out.values()):,} rows", file=sys.stderr)
