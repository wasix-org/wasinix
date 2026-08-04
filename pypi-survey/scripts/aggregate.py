#!/usr/bin/env python3
"""Aggregate the native-package breakdown from wheel_inspect + sdist scans."""

import json
import os
import re
from collections import Counter, defaultdict

BASE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    p = os.path.join(BASE, name)
    return json.load(open(p)) if os.path.exists(p) else {}


classified = load("classified.json")
wheels = load("wheel_inspect.json")
sdists = load("sdist_scan_native_10000.json") or load("sdist_scan_native_1000.json")

native = {k: v for k, v in classified.items() if v.get("final") == "native"}

# --- canonical lib mapping ---------------------------------------------------
LIBMAP = [
    (r"^lib(ssl|crypto)", "openssl"),
    (r"^libz\.so|^libz-|^libzstd", None),  # split below
    (r"^libgfortran|^libquadmath", "gfortran-rt"),
    (r"openblas|^liblapack|^libblas|^libcblas|^libscipy_openblas", "openblas/blas"),
    (r"^libstdc\+\+", "libstdc++"),
    (r"^libgcc", "libgcc"),
    (r"^libgomp|^libomp|^libiomp", "openmp-rt"),
    (r"^libxml2", "libxml2"),
    (r"^libxslt|^libexslt", "libxslt"),
    (r"^libjpeg|^libturbojpeg", "libjpeg"),
    (r"^libpng", "libpng"),
    (r"^libtiff", "libtiff"),
    (r"^libwebp", "libwebp"),
    (r"^libfreetype", "freetype"),
    (r"^libharfbuzz", "harfbuzz"),
    (r"^libsqlite", "sqlite"),
    (r"^libffi", "libffi"),
    (r"^libpq", "libpq (postgres)"),
    (r"^libmysql|^libmariadb", "libmysql/mariadb"),
    (r"^libzmq|^libsodium", None),
    (r"^libevent", "libevent"),
    (r"^libuv", "libuv"),
    (r"^libssh", "libssh"),
    (r"^libkrb|^libgssapi|^libcom_err|^libk5crypto|^libkeyutils", "kerberos"),
    (r"^libsasl", "cyrus-sasl"),
    (r"^libcurl|^libnghttp", "curl-stack"),
    (r"^libbrotli", "brotli"),
    (r"^liblz4", "lz4"),
    (r"^libbz2", "bzip2"),
    (r"^liblzma", "xz"),
    (r"^libsnappy", "snappy"),
    (r"^libabsl|^libprotobuf|^libutf8", "protobuf/absl"),
    (r"^libgrpc|^libupb|^libcares|^libaddress_sorting|^libre2", "grpc-stack"),
    (r"^libarrow|^libparquet", "arrow"),
    (r"^libaws", "aws-sdk-cpp"),
    (
        r"^libcud|^libnv|^libcublas|^libcufft|^libcusparse|^libcusolver|^libnccl|^libcupti",
        "cuda",
    ),
    (r"^libtorch|^libc10|^libshm|^libcaffe", "libtorch"),
    (r"^libtensorflow", "libtensorflow"),
    (r"^libonnx", "onnxruntime"),
    (r"^libopencv", "opencv"),
    (
        r"^libavcodec|^libavformat|^libavutil|^libswscale|^libswresample|^libavfilter|^libavdevice",
        "ffmpeg",
    ),
    (r"^libgeos", "geos"),
    (r"^libproj", "proj"),
    (r"^libgdal", "gdal"),
    (r"^libspatialindex", "spatialindex"),
    (r"^libhdf5", "hdf5"),
    (r"^libnetcdf", "netcdf"),
    (
        r"^libX|^libxcb|^libGL|^libEGL|^libwayland|^libfontconfig|^libglib|^libgobject|^libgio|^libgdk|^libgtk|^libatk|^libcairo|^libpango|^libdbus|^libICE|^libSM|^libxkb",
        "gui/x11-stack",
    ),
    (r"^libQt|^libicudata|^libicui18n|^libicuuc", None),
    (r"^libleveldb|^librocksdb", "leveldb/rocksdb"),
    (r"^libyaml", "libyaml"),
    (r"^libgit2", "libgit2"),
    (r"^libmagic", "libmagic"),
    (r"^libespeak", "espeak"),
    (
        r"^libsndfile|^libFLAC|^libvorbis|^libogg|^libopus|^libmp3lame|^libmpg123",
        "audio-codecs",
    ),
    (r"^libblosc", "blosc"),
    (r"^libre2", "re2"),
]


def canon_lib(b):
    if re.match(r"^libzstd", b):
        return "zstd"
    if re.match(r"^libz\.so|^libz-", b):
        return "zlib"
    if re.match(r"^libzmq", b):
        return "zeromq"
    if re.match(r"^libsodium", b):
        return "libsodium"
    if re.match(r"^libQt", b):
        return "qt"
    if re.match(r"^libicu", b):
        return "icu"
    for pat, name in LIBMAP:
        if name and re.match(pat, b):
            return name
    return re.sub(r"\.(so|dylib|dll)$", "", b)


def gen_bucket(g):
    if not g:
        return "unknown"
    g = g.lower()
    for key in (
        "maturin",
        "meson",
        "scikit-build",
        "skbuild",
        "bazel",
        "hatchling",
        "poetry",
        "flit",
        "pdm",
        "delvewheel",
        "conan",
    ):
        if key in g:
            return {"skbuild": "scikit-build"}.get(
                key, key.replace("scikit-build", "scikit-build")
            )
    if "setuptools" in g or "bdist_wheel" in g:
        return "setuptools"
    return g.split()[0].split("(")[0]


def abi_kind(abis):
    s = set(abis or [])
    if "abi3" in s:
        return "abi3"
    if any(re.match(r"cp3\d+", a) for a in s):
        return "cp-specific"
    if "none" in s:
        return "none (no C API)"
    return ",".join(sorted(s)) or "unknown"


# cffi users from runtime requires
cffi_users = set()
for k in native:
    rec = load(os.path.join("cache", k + ".json"))
    for r in rec.get("requires_dist") or []:
        if re.match(r"^\s*cffi\b", r) and "extra ==" not in r:
            cffi_users.add(k)

# --- language attribution -----------------------------------------------------


def languages(k):
    langs = set()
    w = wheels.get(k) or {}
    sd = sdists.get(k) or {}
    gen = gen_bucket(w.get("generator"))
    exts = sd.get("exts") or {}
    br = " ".join(sd.get("build_requires") or []).lower()
    setup_sig = set(sd.get("setup_signals") or [])
    special = sd.get("special") or {}
    bundled = " ".join(w.get("bundled") or []).lower()

    if (
        gen == "maturin"
        or "setuptools-rust" in br
        or "setuptools_rust" in br
        or exts.get(".rs")
        or special.get("cargo.toml")
        or "rust_extensions" in setup_sig
    ):
        langs.add("rust")
    if exts.get(".pyx") or "cython" in br:
        langs.add("cython")
    if (
        exts.get(".cpp")
        or exts.get(".cc")
        or exts.get(".cxx")
        or "pybind11" in br
        or "nanobind" in br
        or "libstdc++" in bundled
    ):
        langs.add("c++")
    if (
        exts.get(".f")
        or exts.get(".f90")
        or exts.get(".f77")
        or exts.get(".f95")
        or "libgfortran" in bundled
    ):
        langs.add("fortran")
    if (
        k in cffi_users
        or "cffi_modules" in setup_sig
        or ("cffi" in br and "extra" not in br)
    ):
        langs.add("cffi(c)")
    if exts.get(".c", 0) > 0 and "cython" not in langs:
        langs.add("c")
    elif (
        exts.get(".c", 0) > (exts.get(".pyx", 0) or 0) * 1
        and exts.get(".c", 0) > 5
        and "cython" in langs
    ):
        langs.add("c")  # both cython and substantial C
    if not langs:
        # wheel-only fallback
        if gen == "maturin":
            langs.add("rust")
        elif gen in ("setuptools", "meson", "scikit-build", "unknown", "bazel"):
            langs.add("c/c++ (unattributed)")
    return langs


def report(cutoff):
    subset = [k for k, v in native.items() if v["rank"] <= cutoff]
    print(f"\n=== top {cutoff}: {len(subset)} native packages ===")
    gens = Counter(gen_bucket((wheels.get(k) or {}).get("generator")) for k in subset)
    print("generators:", dict(gens.most_common()))
    abis = Counter(abi_kind((wheels.get(k) or {}).get("abi")) for k in subset)
    print("abi kinds:", dict(abis.most_common()))
    plats = Counter((wheels.get(k) or {}).get("plat_kind", "?") for k in subset)
    print("inspected wheel platform:", dict(plats.most_common()))
    print("cffi runtime users:", sum(1 for k in subset if k in cffi_users))

    libs = Counter()
    pkgs_with_bundled = 0
    for k in subset:
        bl = (wheels.get(k) or {}).get("bundled") or []
        cl = {canon_lib(b) for b in bl}
        if cl:
            pkgs_with_bundled += 1
        libs.update(cl)
    print(f"packages bundling shared libs: {pkgs_with_bundled}")
    print("top bundled libs:", libs.most_common(30))

    lang = Counter()
    for k in subset:
        for l in languages(k):
            lang[l] += 1
    print("languages (multi-label):", dict(lang.most_common()))


for cutoff in (100, 1000, 10000):
    report(cutoff)
