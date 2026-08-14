"""Minimal client for the public ClickHouse PyPI dataset (sql-clickhouse.clickhouse.com)."""

import json, sys, urllib.request, urllib.parse, gzip

URL = "https://sql-clickhouse.clickhouse.com/"


# Two traps in the demo profile. It ships max_rows_to_read=1e10 with read_overflow_mode=break,
# so large scans return silently truncated (and run-to-run inconsistent) results; the settings
# below lift that. Separately, a result of more than a few hundred thousand rows is cut off on
# the way out, also non-deterministically. Page through an explicit ORDER BY for those.
SETTINGS = {
    "user": "demo",
    "max_rows_to_read": "0",
    "max_bytes_to_read": "0",
    "max_execution_time": "900",
    "max_result_rows": "0",
}


def query(sql, fmt="JSONCompactEachRow", timeout=600):
    params = urllib.parse.urlencode({**SETTINGS, "default_format": fmt})
    req = urllib.request.Request(
        URL + "?" + params,
        data=sql.encode(),
        headers={"Accept-Encoding": "gzip"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    text = raw.decode()
    if fmt == "JSONCompactEachRow":
        out = []
        for line in text.splitlines():
            if not line.strip():
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                raise RuntimeError("query failed: " + text[:2000])
        return out
    return text


if __name__ == "__main__":
    print(query(sys.stdin.read(), fmt="TabSeparatedWithNames"))
