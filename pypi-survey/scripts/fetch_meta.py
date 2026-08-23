#!/usr/bin/env python3
"""Fetch trimmed PyPI JSON metadata for the top-N packages into cache/."""

import gzip
import io
import json
import os
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

from packaging.version import Version, InvalidVersion

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
CACHE = os.path.join(ROOT, "cache")
UA = "wasinix-pypi-survey/0.1 (claude@blenderfreaky.de)"


def _argn():
    try:
        return int(sys.argv[1])
    except (IndexError, ValueError):
        return 10000


def norm(name: str) -> str:
    return name.lower().replace("_", "-").replace(".", "-")


def get(url: str, tries: int = 4):
    last = None
    for i in range(tries):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": UA, "Accept-Encoding": "gzip"}
            )
            with urllib.request.urlopen(req, timeout=30) as r:
                data = r.read()
                if r.headers.get("Content-Encoding") == "gzip":
                    data = gzip.decompress(data)
                return data
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            last = e
        except Exception as e:
            last = e
        time.sleep(1.5 * (i + 1))
    raise last


def trim_files(files):
    return [
        {
            "filename": f["filename"],
            "packagetype": f["packagetype"],
            "size": f.get("size"),
            "url": f["url"],
            "yanked": bool(f.get("yanked")),
        }
        for f in files
    ]


def pick_release(doc):
    """Return (version, files). Prefer info.version's files; else newest
    non-yanked, non-prerelease release that has files."""
    ver = doc["info"]["version"]
    urls = doc.get("urls") or []
    if urls:
        return ver, trim_files(urls)
    releases = doc.get("releases") or {}
    candidates = []
    for v, files in releases.items():
        if not files:
            continue
        try:
            pv = Version(v)
        except InvalidVersion:
            continue
        if all(f.get("yanked") for f in files):
            continue
        candidates.append((pv.is_prerelease, pv, v, files))
    if not candidates:
        return ver, []
    stable = [c for c in candidates if not c[0]]
    pool = stable if stable else candidates
    _, _, v, files = max(pool, key=lambda t: t[1])
    return v, trim_files(files)


def fetch(name: str):
    path = os.path.join(CACHE, norm(name) + ".json")
    if os.path.exists(path):
        return "cached"
    data = get(f"https://pypi.org/pypi/{name}/json")
    if data is None:
        out = {"name": name, "error": "404"}
    else:
        doc = json.loads(data)
        ver, files = pick_release(doc)
        info = doc["info"]
        out = {
            "name": name,
            "version": ver,
            "requires_dist": info.get("requires_dist"),
            "requires_python": info.get("requires_python"),
            "files": files,
        }
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f)
    os.replace(tmp, path)
    return "fetched"


def main():
    with open(os.path.join(DATA, "top.json")) as f:
        top = json.load(f)
    names = [r["project"] for r in top["rows"]][: _argn()]
    os.makedirs(CACHE, exist_ok=True)
    done = 0
    errors = []
    with ThreadPoolExecutor(max_workers=32) as ex:
        futs = {ex.submit(fetch, n): n for n in names}
        for fut in as_completed(futs):
            name = futs[fut]
            try:
                fut.result()
            except Exception as e:
                errors.append((name, repr(e)))
            done += 1
            if done % 500 == 0:
                print(f"{done}/{len(names)} done, {len(errors)} errors", flush=True)
    print(f"DONE {done}/{len(names)}, {len(errors)} errors")
    for name, err in errors[:30]:
        print("ERR", name, err)


if __name__ == "__main__":
    main()
