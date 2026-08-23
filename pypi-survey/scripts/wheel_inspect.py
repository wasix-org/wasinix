#!/usr/bin/env python3
"""Inspect one representative wheel per native package via HTTP range requests.

Collects, without downloading the whole wheel:
  - generator: the WHEEL file's Generator line (bdist_wheel/maturin/meson/...)
  - ext_modules: number + names of compiled extension .so/.pyd files
  - bundled_libs: basenames of auditwheel/delvewheel-vendored shared libs
  - abi: abi tag of the chosen wheel

Usage: wheel_inspect.py [maxrank]
Writes wheel_inspect.json (resumable).
"""

import io
import json
import os
import re
import sys
import time
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
CACHE = os.path.join(ROOT, "cache")
UA = "wasinix-pypi-survey/0.1 (claude@blenderfreaky.de)"
CHUNK = 128 * 1024


class HttpFile(io.RawIOBase):
    """Seekable read-only file over HTTP range requests, chunk-cached."""

    def __init__(self, url, size):
        self.url, self.size, self.pos = url, size, 0
        self.chunks = {}
        self.nreq = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        if whence == 0:
            self.pos = off
        elif whence == 1:
            self.pos += off
        else:
            self.pos = self.size + off
        return self.pos

    def _fetch(self, start, end):
        req = urllib.request.Request(
            self.url,
            headers={"User-Agent": UA, "Range": f"bytes={start}-{end - 1}"},
        )
        self.nreq += 1
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read()

    def readinto(self, b):
        data = self.read(len(b))
        b[: len(data)] = data
        return len(data)

    def read(self, n=-1):
        if n < 0:
            n = self.size - self.pos
        n = min(n, self.size - self.pos)
        if n <= 0:
            return b""
        out = bytearray()
        pos = self.pos
        first, last = pos // CHUNK, (pos + n - 1) // CHUNK
        # fetch any missing chunk span in one request
        missing = [c for c in range(first, last + 1) if c not in self.chunks]
        if missing:
            lo = missing[0] * CHUNK
            hi = min((missing[-1] + 1) * CHUNK, self.size)
            data = self._fetch(lo, hi)
            for c in range(missing[0], missing[-1] + 1):
                s = c * CHUNK - lo
                self.chunks[c] = data[s : s + CHUNK]
        for c in range(first, last + 1):
            chunk = self.chunks[c]
            s = max(0, pos - c * CHUNK)
            e = min(len(chunk), pos + n - c * CHUNK)
            out += chunk[s:e]
        self.pos += len(out)
        return bytes(out)


def wheel_tags(filename):
    stem = filename[: -len(".whl")]
    parts = stem.split("-")
    return parts[-3].split("."), parts[-2].split("."), parts[-1].split(".")


def plat_score(plats):
    s = " ".join(plats)
    if "manylinux" in s and "x86_64" in s:
        return 6
    if "musllinux" in s and "x86_64" in s:
        return 5
    if "linux" in s:
        return 4
    if "macosx" in s:
        return 3
    if "win" in s:
        return 2
    return 1


def py_score(pytags):
    best = 0
    for t in pytags:
        m = re.match(r"cp3(\d+)", t)
        if m:
            best = max(best, 100 + int(m.group(1)))
        elif t.startswith("py3"):
            best = max(best, 50)
    return best


def pick_wheel(files):
    wheels = [f for f in files if f["packagetype"] == "bdist_wheel"]
    scored = []
    for w in wheels:
        try:
            py, abi, plat = wheel_tags(w["filename"])
        except Exception:
            continue
        if plat == ["any"]:
            continue
        freethreaded = any(t.endswith("t") for t in abi)
        scored.append((plat_score(plat), not freethreaded, py_score(py), w, abi, plat))
    if not scored:
        return None
    scored.sort(key=lambda t: (t[0], t[1], t[2]))
    _, _, _, w, abi, plat = scored[-1]
    return w, abi, plat


LIBHASH = re.compile(r"(?:[-.][0-9a-f]{8,})+(?=\.so|\.dylib|\.dll)", re.I)


def libbase(path):
    b = os.path.basename(path)
    b = LIBHASH.sub("", b)
    # strip trailing .so.1.2.3 version suffix -> keep libname.so
    b = re.sub(r"(\.so)(\.\d+)+$", r"\1", b)
    return b


EXTMOD = re.compile(r"\.(cpython-\d+[\w-]*\.so|abi3\.so|pyd|so)$")


def inspect_one(key, rec):
    cache = json.load(open(os.path.join(CACHE, key + ".json")))
    picked = pick_wheel(cache.get("files") or [])
    if not picked:
        return key, {"error": "no_platform_wheel"}
    w, abi, plat = picked
    out = {
        "wheel": w["filename"],
        "abi": abi,
        "plat_kind": (
            "manylinux"
            if any("manylinux" in p for p in plat)
            else "musllinux"
            if any("musllinux" in p for p in plat)
            else "macosx"
            if any("macosx" in p for p in plat)
            else "win"
            if any("win" in p for p in plat)
            else "other"
        ),
        "size": w.get("size"),
    }
    try:
        hf = HttpFile(w["url"], w["size"])
        zf = zipfile.ZipFile(io.BufferedReader(hf, 1 << 16))
        names = zf.namelist()
        extmods, bundled = [], []
        for n in names:
            low = n.lower()
            if "/tests/" in low or "/test/" in low:
                pass
            if EXTMOD.search(low):
                if ".libs/" in low or "/.dylibs/" in low or low.startswith(tuple()):
                    bundled.append(libbase(n))
                elif os.path.basename(low).startswith("lib") and ".libs" in low:
                    bundled.append(libbase(n))
                else:
                    extmods.append(os.path.basename(n))
            elif low.endswith((".dylib", ".dll")) or ".so." in os.path.basename(low):
                bundled.append(libbase(n))
        # anything under *.libs/ or .dylibs/ is vendored, even plain .so
        for n in names:
            low = n.lower()
            if (".libs/" in low or "/.dylibs/" in low) and low.endswith(".so"):
                b = libbase(n)
                if b not in bundled:
                    bundled.append(b)
                base = os.path.basename(n)
                if base in extmods:
                    extmods.remove(base)
        out["n_ext"] = len(extmods)
        out["ext_sample"] = extmods[:8]
        out["bundled"] = sorted(set(bundled))
        wheel_meta = [n for n in names if n.endswith(".dist-info/WHEEL")]
        if wheel_meta:
            txt = zf.read(wheel_meta[0]).decode("utf-8", "replace")
            m = re.search(r"^Generator:\s*(.+)$", txt, re.M)
            out["generator"] = m.group(1).strip() if m else None
        out["nreq"] = hf.nreq
    except Exception as e:
        out["error"] = repr(e)
    return key, out


def main():
    maxrank = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
    with open(os.path.join(DATA, "classified.json")) as f:
        classified = json.load(f)
    outpath = os.path.join(DATA, "wheel_inspect.json")
    results = {}
    if os.path.exists(outpath):
        with open(outpath) as f:
            results = json.load(f)
    todo = {
        k: v
        for k, v in classified.items()
        if v["class"] == "native" and v["rank"] <= maxrank and k not in results
    }
    print(f"{len(todo)} native packages to inspect")
    done = 0
    with ThreadPoolExecutor(max_workers=24) as ex:
        futs = [ex.submit(inspect_one, k, v) for k, v in todo.items()]
        for fut in as_completed(futs):
            try:
                key, out = fut.result()
                results[key] = out
            except Exception as e:
                print("ERR", repr(e))
            done += 1
            if done % 100 == 0:
                print(f"{done}/{len(todo)}", flush=True)
                with open(outpath, "w") as f:
                    json.dump(results, f)
    with open(outpath, "w") as f:
        json.dump(results, f, indent=1)
    errs = sum(1 for v in results.values() if v.get("error"))
    print(f"DONE {len(results)} inspected, {errs} errors")


if __name__ == "__main__":
    main()
