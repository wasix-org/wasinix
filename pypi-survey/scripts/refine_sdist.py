#!/usr/bin/env python3
"""Turn sdist_scan signals into pure/native verdicts -> sdist_refined.json."""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")

NATIVE_SETUP = {
    "ext_modules",
    "Extension(",
    "cythonize",
    "cffi_modules",
    "rust_extensions",
}
NATIVE_BACKENDS = (
    "maturin",
    "scikit_build_core",
    "mesonpy",
    "enscons",
    "setuptools_rust",
)
NATIVE_BUILDREQ = (
    "cython",
    "pybind11",
    "maturin",
    "setuptools-rust",
    "setuptools_rust",
    "cffi",
    "scikit-build",
    "meson",
    "cmake",
    "nanobind",
    "numpy",
)  # numpy in build-req usually => compiled against C API


def verdict(sig):
    if sig.get("no_sdist"):
        return "unknown", "no_sdist"
    if sig.get("skipped") or sig.get("error"):
        return "unknown", sig.get("skipped") or "error"
    reasons = []
    setup_hits = set(sig.get("setup_signals") or []) & NATIVE_SETUP
    if setup_hits:
        reasons.append("setup:" + ",".join(sorted(setup_hits)))
    exts = sig.get("exts") or {}
    for e in (".pyx", ".rs", ".f", ".f90", ".f77", ".f95", ".go"):
        if exts.get(e):
            reasons.append(f"src:{e}x{exts[e]}")
    special = sig.get("special") or {}
    if special.get("cargo.toml"):
        reasons.append("cargo")
    bb = sig.get("build_backend") or ""
    if any(b in bb for b in NATIVE_BACKENDS):
        reasons.append(f"backend:{bb}")
    br = " ".join(sig.get("build_requires") or []).lower()
    br_hits = [b for b in NATIVE_BUILDREQ if b in br]
    if br_hits:
        reasons.append("buildreq:" + ",".join(br_hits))
    # C/C++ sources only count when setup.py also builds extensions —
    # vendored .c files alone are common in pure packages (docs, tests).
    if (
        not reasons
        and (exts.get(".c", 0) + exts.get(".cpp", 0) + exts.get(".cc", 0)) >= 3
    ):
        return "borderline_c", f"c_sources_only:{exts}"
    if reasons:
        return "native", ";".join(reasons)
    return "pure", ""


def main():
    cutoff = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
    with open(os.path.join(DATA, f"sdist_scan_sdist_only_{cutoff}.json")) as f:
        scans = json.load(f)
    with open(os.path.join(DATA, "classified.json")) as f:
        classified = json.load(f)

    refined = {}
    counts = {}
    borderline, unknown = [], []
    for key, sig in scans.items():
        v, why = verdict(sig)
        counts[v] = counts.get(v, 0) + 1
        if v == "borderline_c":
            borderline.append((classified[key]["rank"], key, why))
        if v == "unknown":
            unknown.append((classified[key]["rank"], key, why))
        refined[key] = v if v in ("native", "pure") else "unknown_" + v
    with open(os.path.join(DATA, "sdist_refined.json"), "w") as f:
        json.dump(refined, f, indent=1)
    print(counts)
    print("\nborderline (C sources but no ext_modules signal):")
    for r, k, why in sorted(borderline):
        print(f"  #{r} {k}: {why[:120]}")
    print("\nunknown:")
    for r, k, why in sorted(unknown)[:30]:
        print(f"  #{r} {k}: {why}")


if __name__ == "__main__":
    main()
