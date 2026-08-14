"""Render the standalone HTML report from the computed aggregates."""

import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA, OUT = f"{HERE}/../data", f"{HERE}/.."

P = json.load(open(f"{DATA}/page_data.json"))
recs = json.load(open(f"{DATA}/recommend.json"))
A, B, C = P["A"], P["B"], P["C"]

payload = {
    "A": A,
    "B": B,
    "C": C,
    "build": [r for r in recs if r["verdict"] in ("breaking", "unknown")][:60],
    "alias": [r for r in recs if r["verdict"] in ("safe", "probably-safe")][:40],
}

tpl = open(f"{HERE}/template.html").read()
html = tpl.replace("/*__DATA__*/null", json.dumps(payload, separators=(",", ":")))
open(f"{OUT}/report.html", "w").write(html)
print(f"wrote report.html ({len(html):,} bytes)")
