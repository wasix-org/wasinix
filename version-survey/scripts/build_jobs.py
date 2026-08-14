"""Choose which (project, version) wheels to introspect for the API diff."""

import gzip, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE, DATA = f"{HERE}/../cache", f"{HERE}/../data"
NPROJ = int(sys.argv[1]) if len(sys.argv) > 1 else 300
MIN_SHARE = 0.02
MAX_PER_PROJECT = 6

usage = json.load(open(f"{DATA}/usage.json"))
projs = sorted(usage.items(), key=lambda kv: -kv[1]["covered"])[:NPROJ]

jobs, targets, skipped = [], {}, []
for p, u in projs:
    with gzip.open(f"{CACHE}/{p}.json.gz", "rt") as fh:
        rel = json.load(fh)["rel"]

    def url_for(v):
        e = rel.get(v)
        if e is None:
            for k in rel:  # canonical vs raw version string
                if k.replace("-", ".") == v or k == v:
                    e = rel[k]
                    break
        if e and e.get("whl"):
            return e["whl"][0], e["whl"][1] or 0
        return None, 0

    wanted = [u["latest"]] + [
        tv["v"]
        for tv in u["top_versions"]
        if tv["v"] != u["latest"] and tv["share"] >= MIN_SHARE
    ][:MAX_PER_PROJECT]
    got = []
    for v in wanted:
        url, size = url_for(v)
        if not url:
            skipped.append((p, v, "no wheel"))
            continue
        if size > 40 * 1024 * 1024:
            skipped.append((p, v, f"wheel {size // 1048576}MB"))
            continue
        jobs.append([p, v, url])
        got.append(v)
    if len(got) > 1:
        targets[p] = {"latest": u["latest"], "versions": got}

json.dump(jobs, open(f"{DATA}/api_jobs.json", "w"))
json.dump(targets, open(f"{DATA}/api_targets.json", "w"))
print(
    f"{len(jobs)} wheels over {len(targets)} projects; {len(skipped)} skipped",
    file=sys.stderr,
)
print(f"first skips: {skipped[:8]}", file=sys.stderr)
