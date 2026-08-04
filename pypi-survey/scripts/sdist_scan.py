#!/usr/bin/env python3
"""Stream-scan sdists for native-code signals.

Usage: sdist_scan.py <class> [maxrank]
  <class> = sdist_only | native   (which classified.json group to scan)

Writes sdist_scan_<class>.json: per-package signals
  - exts: counts of interesting source extensions
  - build_requires: [build-system] requires from pyproject.toml
  - build_backend: from pyproject.toml
  - setup_signals: markers found in setup.py (ext_modules, Extension, cythonize)
  - special files: Cargo.toml, CMakeLists.txt, meson.build, configure
"""

import io
import json
import os
import re
import sys
import tarfile
import time
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed

BASE = os.path.dirname(os.path.abspath(__file__))
UA = "wasinix-pypi-survey/0.1 (claude@blenderfreaky.de)"
MAX_COMPRESSED = int(os.environ.get("MAX_MB", "40")) * 1024 * 1024

INTERESTING_EXT = {
    ".pyx",
    ".pxd",
    ".c",
    ".h",
    ".cc",
    ".cpp",
    ".cxx",
    ".hpp",
    ".rs",
    ".f",
    ".f77",
    ".f90",
    ".f95",
    ".go",
    ".s",
    ".asm",
}
SPECIAL = {"cargo.toml", "cmakelists.txt", "meson.build", "configure", "makefile"}


def norm(name: str) -> str:
    return name.lower().replace("_", "-").replace(".", "-")


class CappedReader(io.RawIOBase):
    def __init__(self, resp, cap):
        self.resp, self.cap, self.count = resp, cap, 0

    def readable(self):
        return True

    def readinto(self, b):
        if self.count >= self.cap:
            return 0
        n = self.resp.readinto(b)
        self.count += n or 0
        return n


def scan_tar(fileobj, out):
    tf = tarfile.open(fileobj=fileobj, mode="r|*")
    seen_pyproject = seen_setup = False
    for member in tf:
        if not member.isfile():
            continue
        path = member.name
        base = os.path.basename(path).lower()
        depth = path.count("/")
        _, ext = os.path.splitext(base)
        if ext in INTERESTING_EXT:
            out["exts"][ext] = out["exts"].get(ext, 0) + 1
        if base in SPECIAL:
            out["special"][base] = out["special"].get(base, 0) + 1
        if base == "pyproject.toml" and depth <= 1 and not seen_pyproject:
            seen_pyproject = True
            try:
                data = tf.extractfile(member).read(200_000).decode("utf-8", "replace")
                parse_pyproject(data, out)
            except Exception:
                pass
        elif base == "setup.py" and depth <= 1 and not seen_setup:
            seen_setup = True
            try:
                data = tf.extractfile(member).read(300_000).decode("utf-8", "replace")
                for marker in (
                    "ext_modules",
                    "Extension(",
                    "cythonize",
                    "cffi_modules",
                    "build_ext",
                    "rust_extensions",
                ):
                    if marker in data:
                        out["setup_signals"].append(marker)
            except Exception:
                pass
    return out


def parse_pyproject(data, out):
    try:
        import tomllib

        doc = tomllib.loads(data)
        bs = doc.get("build-system", {})
        out["build_backend"] = bs.get("build-backend")
        out["build_requires"] = bs.get("requires", [])
    except Exception:
        m = re.search(r'build-backend\s*=\s*"([^"]+)"', data)
        if m:
            out["build_backend"] = m.group(1)


def scan_one(item):
    name, url, size = item["pkg"], item["url"], item.get("size") or 0
    out = {
        "exts": {},
        "special": {},
        "setup_signals": [],
        "build_backend": None,
        "build_requires": None,
        "sdist_size": size,
    }
    if size and size > MAX_COMPRESSED:
        out["skipped"] = "too_large"
        return name, out
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                capped = io.BufferedReader(CappedReader(resp, MAX_COMPRESSED), 1 << 16)
                if url.endswith(".zip"):
                    data = capped.read()
                    zf = zipfile.ZipFile(io.BytesIO(data))
                    for zi in zf.infolist():
                        base = os.path.basename(zi.filename).lower()
                        _, ext = os.path.splitext(base)
                        if ext in INTERESTING_EXT:
                            out["exts"][ext] = out["exts"].get(ext, 0) + 1
                        if base in SPECIAL:
                            out["special"][base] = out["special"].get(base, 0) + 1
                        if base == "pyproject.toml" and zi.filename.count("/") <= 1:
                            parse_pyproject(zf.read(zi).decode("utf-8", "replace"), out)
                else:
                    scan_tar(capped, out)
            return name, out
        except Exception as e:
            err = repr(e)
            time.sleep(1 + attempt)
    out["error"] = err
    return name, out


def main():
    cls = sys.argv[1]
    maxrank = int(sys.argv[2]) if len(sys.argv) > 2 else 10000
    with open(os.path.join(BASE, "classified.json")) as f:
        classified = json.load(f)
    outpath = os.path.join(BASE, f"sdist_scan_{cls}_{maxrank}.json")
    results = {}
    if os.path.exists(outpath):
        with open(outpath) as f:
            results = json.load(f)

    todo = []
    for key, rec in classified.items():
        if rec["class"] != cls or rec["rank"] > maxrank or key in results:
            continue
        if cls == "sdist_only":
            url, size = rec.get("sdist_url"), rec.get("sdist_size")
        else:
            cache = json.load(open(os.path.join(BASE, "cache", key + ".json")))
            sd = [f for f in cache.get("files") or [] if f["packagetype"] == "sdist"]
            if not sd:
                results[key] = {"no_sdist": True}
                continue
            url, size = sd[0]["url"], sd[0].get("size")
        if not url:
            results[key] = {"no_sdist": True}
            continue
        todo.append({"pkg": key, "url": url, "size": size})

    print(f"{len(todo)} sdists to scan for class={cls} rank<={maxrank}")
    done = 0
    with ThreadPoolExecutor(max_workers=16) as ex:
        futs = [ex.submit(scan_one, it) for it in todo]
        for fut in as_completed(futs):
            name, out = fut.result()
            results[name] = out
            done += 1
            if done % 50 == 0:
                print(f"{done}/{len(todo)}", flush=True)
                with open(outpath, "w") as f:
                    json.dump(results, f)
    with open(outpath, "w") as f:
        json.dump(results, f, indent=1)
    print(f"DONE {done} scanned -> {outpath}")


if __name__ == "__main__":
    main()
