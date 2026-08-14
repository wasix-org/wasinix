"""Reduce PyPI's simple-index JSON to a per-version record for each surveyed project.

Keeps upload time, yank state and the distinct wheel tags (which tell pure from
native without downloading anything).
"""

import gzip, json, os, re, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache")
DATA = os.path.join(HERE, "..", "data")
os.makedirs(CACHE, exist_ok=True)

WHEEL = re.compile(
    r"^(?P<name>.+?)-(?P<ver>.+?)(-\d[^-]*)?-(?P<py>[^-]+)-(?P<abi>[^-]+)-(?P<plat>[^-]+)\.whl$"
)


def wheel_rank(tags):
    """Prefer a pure wheel, then a modern manylinux x86_64 build; anything else last."""
    py, abi, plat = tags
    if plat == "any":
        return (0, 0)
    if "manylinux" in plat and ("x86_64" in plat or "aarch64" in plat):
        if abi == "abi3":
            return (1, 0)
        n = int(py[2:5]) if py.startswith("cp") and py[2:5].isdigit() else 0
        return (2, -n)
    return (3, 0)


def better_wheel(cur, tags, f):
    if cur is None:
        return True
    return wheel_rank(tags) < wheel_rank(tuple(cur[2].split("-")))


def reduce_project(name):
    req = urllib.request.Request(
        f"https://pypi.org/simple/{name}/",
        headers={
            "Accept": "application/vnd.pypi.simple.v1+json",
            "Accept-Encoding": "gzip",
            "User-Agent": "wasinix-version-survey",
        },
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
        if r.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
    d = json.loads(raw)
    out = {}
    for f in d["files"]:
        fn = f["filename"]
        m = WHEEL.match(fn)
        if m:
            ver, tags = m["ver"], (m["py"], m["abi"], m["plat"])
        elif fn.endswith((".tar.gz", ".zip", ".tar.bz2")):
            ver, tags = None, None  # version parsed below from the version list
        else:
            continue
        if ver is None:
            # sdist: strip the known project prefix, then the extension
            stem = (
                fn.rsplit(".tar.gz", 1)[0].rsplit(".zip", 1)[0].rsplit(".tar.bz2", 1)[0]
            )
            if "-" not in stem:
                continue
            ver = stem.rsplit("-", 1)[1]
        e = out.setdefault(
            ver,
            {
                "t": None,
                "y": True,
                "sdist": False,
                "tags": set(),
                "whl": None,
                "sd": None,
            },
        )
        t = f.get("upload-time")
        if t and (e["t"] is None or t < e["t"]):
            e["t"] = t
        if not f.get("yanked"):
            e["y"] = False
        if tags is None:
            e["sdist"] = True
            if e["sd"] is None:
                e["sd"] = [f["url"], f.get("size")]
        else:
            e["tags"].add("-".join(tags))
            if better_wheel(e["whl"], tags, f):
                e["whl"] = [f["url"], f.get("size"), "-".join(tags)]
    for v in out.values():
        v["tags"] = sorted(v["tags"])
    return {
        "versions": d.get("versions", []),
        "status": d.get("project-status"),
        "rel": out,
    }


def main():
    top = [r["project"] for r in json.load(open(f"{DATA}/top.json"))["rows"]]
    todo = [p for p in top if not os.path.exists(f"{CACHE}/{p}.json.gz")]
    print(f"{len(top)} projects, {len(todo)} to fetch", file=sys.stderr)

    def work(p):
        try:
            r = reduce_project(p)
        except Exception as ex:
            return p, str(ex)
        with gzip.open(f"{CACHE}/{p}.json.gz", "wt") as fh:
            json.dump(r, fh)
        return p, None

    bad = []
    with ThreadPoolExecutor(16) as ex:
        for i, (p, err) in enumerate(ex.map(work, todo), 1):
            if err:
                bad.append((p, err))
            if i % 100 == 0:
                print(f"  {i}/{len(todo)}", file=sys.stderr)
    print(f"failed: {bad}", file=sys.stderr)


if __name__ == "__main__":
    main()
