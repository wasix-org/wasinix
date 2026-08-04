#!/usr/bin/env python3
"""Assemble page_data.json (for the flame page) and findings.md (detail doc)."""

import json
import os
import sys
from collections import Counter

BASE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = sys.argv[1]

import aggregate as ag  # noqa: E402  (prints its report on import; harmless)

classified = json.load(open(os.path.join(BASE, "classified.json")))
transitive = json.load(open(os.path.join(BASE, "transitive.json")))
optional = json.load(open(os.path.join(BASE, "native_optional.json")))
reach = json.load(open(os.path.join(OUTDIR, "data", "reach.json")))
top = json.load(open(os.path.join(BASE, "top.json")))
downloads = {
    r["project"].lower().replace("_", "-").replace(".", "-"): r["download_count"]
    for r in top["rows"]
}

native = {k: v for k, v in classified.items() if v.get("final") == "native"}


# one primary language category per native package.
# Rust needs a toolchain signal (vendored .rs/Cargo.toml in sdists — e.g. numpy —
# must not count); C vs C++ by source majority; ext_modules with no shipped
# sources means generated C (mypyc and friends).
def lang_cat(k):
    w = ag.wheels.get(k) or {}
    sd = ag.sdists.get(k) or {}
    gen = ag.gen_bucket(w.get("generator"))
    br = " ".join(sd.get("build_requires") or []).lower()
    bb = (sd.get("build_backend") or "").lower()
    sig = set(sd.get("setup_signals") or [])
    exts = sd.get("exts") or {}
    bundled = " ".join(w.get("bundled") or []).lower()
    cpp = exts.get(".cpp", 0) + exts.get(".cc", 0) + exts.get(".cxx", 0)
    cc = exts.get(".c", 0)
    if (
        gen == "maturin"
        or "maturin" in bb
        or "setuptools-rust" in br
        or "setuptools_rust" in br
        or "rust_extensions" in sig
    ):
        return "rust"
    if exts.get(".pyx") or "cython" in br:
        return "cython"
    if cpp > cc or (cpp == cc == 0 and ("pybind11" in br or "nanobind" in br)):
        return "c++" if cpp or "pybind11" in br or "nanobind" in br else "c"
    if cc or "cffi" in br or "cffi_modules" in sig:
        return "c"
    if sig & {"ext_modules", "Extension(", "build_ext"}:
        return "c"  # builds extensions from generated sources (mypyc etc.)
    if "libstdc++" in bundled:
        return "c++"
    return "binary/unknown"


langcats = {k: lang_cat(k) for k in native}

# ---- KPIs ----
kpis = {}
for cutoff in (100, 1000, 10000):
    sub = [
        v
        for v in classified.values()
        if v["rank"] <= cutoff and v.get("final") != "excluded"
    ]
    tsub = [v for v in transitive.values() if v["rank"] <= cutoff]
    kpis[cutoff] = {
        "total": len(sub),
        "pure": sum(1 for v in sub if v["final"] == "pure"),
        "native": sum(1 for v in sub if v["final"] == "native"),
        "native_self": sum(1 for v in tsub if v["verdict"] == "native_self"),
        "native_deps": sum(1 for v in tsub if v["verdict"] == "native_deps"),
        "pure_closure": sum(1 for v in tsub if v["verdict"] == "pure_closure"),
        "unknown": sum(1 for v in tsub if v["verdict"] == "unknown"),
        "fallback": sum(1 for k2, r in optional.items() if r <= cutoff),
    }

# ---- breakdowns per cutoff ----
breakdowns = {}
for cutoff in (100, 1000, 10000):
    sub = [k for k, v in native.items() if v["rank"] <= cutoff]
    gens = Counter(
        ag.gen_bucket((ag.wheels.get(k) or {}).get("generator")) for k in sub
    )
    abis = Counter(ag.abi_kind((ag.wheels.get(k) or {}).get("abi")) for k in sub)
    langs = Counter(langcats[k] for k in sub)
    libs = Counter()
    for k in sub:
        libs.update(
            {ag.canon_lib(b) for b in (ag.wheels.get(k) or {}).get("bundled") or []}
        )
    breakdowns[cutoff] = {
        "generators": gens.most_common(),
        "abis": abis.most_common(),
        "languages": langs.most_common(),
        "bundled": libs.most_common(25),
        "cffi_users": sum(1 for k in sub if k in ag.cffi_users),
        "n": len(sub),
    }

# ---- reach top list ----
reach_rows = []
for k, r in list(reach.items())[:60]:
    reach_rows.append(
        {
            "pkg": k,
            "pkgs": r["pkgs"],
            "dl": r["downloads"],
            "own": r["own_downloads"],
            "rank": r["rank"],
            "lang": langcats.get(k, "binary/unknown"),
        }
    )

# ---- culprits ----
culprits = {}
for cutoff in (1000, 10000):
    c = Counter()
    for v in transitive.values():
        if v["rank"] <= cutoff and v["verdict"] == "native_deps":
            c.update(v["native_direct"])
    culprits[cutoff] = c.most_common(20)

page_data = {
    "generated": "2026-07-16",
    "kpis": kpis,
    "breakdowns": breakdowns,
    "reach": reach_rows,
    "langcats": langcats,
    "culprits": culprits,
}
with open(os.path.join(OUTDIR, "data", "page_data.json"), "w") as f:
    json.dump(page_data, f)

# =================== findings.md ===================
L = []
add = L.append
add("# PyPI top-10k native-dependency survey — detailed findings\n")
add(
    "Survey date: **2026-07-16**, ranking by 30-day downloads "
    "([hugovk/top-pypi-packages](https://hugovk.github.io/top-pypi-packages/), snapshot 2026-07-01, ClickHouse source). "
    "See README.md for methodology and reproduction steps.\n"
)

add("## 1. Pure Python vs native (the package itself)\n")
add("| cutoff | pure | native | % native | native w/ pure fallback wheel |")
add("|---|---|---|---|---|")
for c in (100, 1000, 10000):
    k = kpis[c]
    add(
        f"| top {c:,} | {k['pure']:,} | {k['native']:,} | {k['native'] / k['total'] * 100:.1f}% | {k['fallback']} |"
    )
add("")
add(
    "“Native” = the latest release publishes at least one platform-specific wheel, or its sdist "
    "builds compiled code (`ext_modules`, Cython, Cargo, CMake/meson, …). Two placeholder packages "
    "(`aaaaaaaaa`, `timedelta`) are 404/fileless and excluded from top-10k percentages. "
    "`pyspark` counts as pure: its 450 MB payload is JVM jars, not compiled CPython extensions.\n"
)

add("## 2. Transitive: does the runtime dependency closure contain native code?\n")
add("Markers evaluated for CPython 3.12 / linux / x86_64, default extras only.\n")
add(
    "| cutoff | pure closure | pure pkg, native deps | native itself | needs native anywhere |"
)
add("|---|---|---|---|---|")
for c in (100, 1000, 10000):
    k = kpis[c]
    needs = k["native_self"] + k["native_deps"]
    add(
        f"| top {c:,} | {k['pure_closure']:,} | {k['native_deps']:,} | {k['native_self']:,} | "
        f"{needs:,} ({needs / k['total'] * 100:.1f}%) |"
    )
add("")
add(
    "Most common *direct* native dependencies among pure packages that pull native code:\n"
)
add("| top 1,000 | count | top 10,000 | count |")
add("|---|---|---|---|")
for (a, ca), (b, cb) in zip(culprits[1000][:15], culprits[10000][:15]):
    add(f"| {a} | {ca} | {b} | {cb} |")
add("")

add("## 3. Native packages: what they're built from\n")
for c in (100, 1000, 10000):
    b = breakdowns[c]
    add(f"### Top {c:,} — {b['n']} native packages\n")
    add("| build backend | n | | abi kind | n | | primary language | n |")
    add("|---|---|---|---|---|---|---|---|")
    rows = max(len(b["generators"]), len(b["abis"]), len(b["languages"]))
    for i in range(rows):
        g = (
            f"{b['generators'][i][0]} | {b['generators'][i][1]}"
            if i < len(b["generators"])
            else " | "
        )
        a = f"{b['abis'][i][0]} | {b['abis'][i][1]}" if i < len(b["abis"]) else " | "
        lg = (
            f"{b['languages'][i][0]} | {b['languages'][i][1]}"
            if i < len(b["languages"])
            else " | "
        )
        add(f"| {g} | | {a} | | {lg} |")
    add("")
    add(
        f"cffi runtime users: {b['cffi_users']}. Most-bundled shared libraries "
        "(auditwheel-vendored in manylinux wheels):\n"
    )
    add("| lib | pkgs | lib | pkgs | lib | pkgs |")
    add("|---|---|---|---|---|---|")
    bl = b["bundled"]
    for i in range(0, min(24, len(bl)), 3):
        cells = []
        for j in range(3):
            if i + j < len(bl):
                cells += [bl[i + j][0], str(bl[i + j][1])]
            else:
                cells += ["", ""]
        add("| " + " | ".join(cells) + " |")
    add("")

add("## 4. The 25 native packages in the top 100\n")
add("| rank | package | build | language | pure fallback wheel |")
add("|---|---|---|---|---|")
for r, k in sorted((v["rank"], k) for k, v in native.items() if v["rank"] <= 100):
    gen = str((ag.wheels.get(k) or {}).get("generator", "?")).split("(")[0].strip()
    add(f"| {r} | {k} | {gen} | {langcats[k]} | {'yes' if k in optional else ''} |")
add("")

add("## 5. Native reach — how much each native package is pulled\n")
add(
    "For every top-10k package, its runtime closure was computed; a native package's *reach* is how many "
    "top-10k packages contain it. Download-weighting sums the dependents' 30-day downloads.\n"
)
add(
    "| native package | own rank | pulled by (pkgs) | dl-weighted (30d) | own downloads (30d) | language |"
)
add("|---|---|---|---|---|---|")
for row in reach_rows[:50]:
    add(
        f"| {row['pkg']} | {row['rank'] or '—'} | {row['pkgs']:,} | {row['dl'] / 1e9:.2f} B | "
        f"{row['own'] / 1e6:,.0f} M | {row['lang']} |"
    )
add("")
add(
    "The interactive flame chart (`flame.html`) shows the same data subdivided by *route*: "
    "under each native package, the direct dependents through which the pulls flow.\n"
)

with open(os.path.join(OUTDIR, "findings.md"), "w") as f:
    f.write("\n".join(L))
print("wrote", os.path.join(OUTDIR, "findings.md"), "and page_data.json")
