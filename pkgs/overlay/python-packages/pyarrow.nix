# pyarrow for wasix, over the minimal static arrow-cpp (see
# overlay/packages/arrow-cpp.nix): parquet but no dataset/orc/flight/cloud-fs
# extensions, all of arrow linked into libarrow_python.so (wasm has no shared
# libarrow). The patch --whole-archives libarrow.a + libparquet.a into
# libarrow_python.so so every symbol is exported for the cython modules.
#
# pyarrow 24.0.0 builds via scikit-build-core (build-backend _build_backend, a thin license-symlink
# wrapper over it); the old setup.py path and its PYARROW_CMAKE_OPTIONS/PYARROW_WITH_* env vars are
# gone (the source ignores them). nixpkgs forwards `cmakeFlags` to scikit-build-core as
# -Ccmake.args, and that is how the cross toolchain (CMAKE_SYSTEM_NAME=Wasi, ...) already reaches
# cmake, so the arrow config and the wasix python/numpy headers go through cmakeFlags too. cmake
# would otherwise probe the build python and compile against native (64-bit long) headers, and
# arrow's SetupCxxFlags fatals ("Unknown system processor") without ARROW_CPU_FLAG.
{
  pyprev,
  wasixPython,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
  py = wasixPython;
  crossNumpyInc = "${py.pkgs.numpy}/lib/${py.libPrefix}/site-packages/numpy/_core/include";
in
  wheels.onlyOnWasix pyprev.pyarrow (
    helpers.libTweaks {
      patches = [./patches/pyarrow-static-arrow-wasix.patch];
      # libcst is a build-system req only for scripts/update_stub_docstrings.py (a maintenance
      # script a wheel build never runs); nixpkgs pulls a *native* libcst that fails under the
      # shared setuptools-rust hook (rustc has no wasm32-wasmer-wasi-dl target). Drop it from the
      # inputs (so the native wheel isn't pulled) and from pyproject's requires (else
      # `build --no-isolation` errors "Missing dependencies: libcst").
      nativeBuildInputs = ni: builtins.filter (p: !(lib.hasInfix "libcst" (toString (p.name or p.pname or "")))) ni;
      postPatch = ''
        substituteInPlace pyproject.toml --replace-fail '"libcst>=1.8.6",' ""
      '';
      # all modules (cython .so + libarrow_python.so) land in site-packages/pyarrow; wasmer
      # resolves the NEEDED libarrow_python.so via the dylink RUNPATH ($ORIGIN is supported).
      env.NIX_LDFLAGS = "--rpath=$ORIGIN";
      cmakeFlags = [
        "-DARROW_CPU_FLAG=wasm32"
        "-DARROW_SIMD_LEVEL=NONE"
        "-DARROW_RUNTIME_SIMD_LEVEL=NONE"
        # parquet is on (arrow-cpp.nix builds it); the other integrations aren't in the minimal
        # arrow-cpp, so force them off. CMakeLists' define_option leaves each PYARROW_<NAME> at
        # "AUTO" and would otherwise honour nixpkgs' PYARROW_WITH_<NAME>=1 env (dataset/hdfs) and
        # fatal against our arrow.
        "-DPYARROW_PARQUET=ON"
        "-DPYARROW_DATASET=OFF"
        "-DPYARROW_ACERO=OFF"
        "-DPYARROW_PARQUET_ENCRYPTION=OFF"
        "-DPYARROW_SUBSTRAIT=OFF"
        "-DPYARROW_FLIGHT=OFF"
        "-DPYARROW_GANDIVA=OFF"
        "-DPYARROW_CUDA=OFF"
        "-DPYARROW_ORC=OFF"
        "-DPYARROW_AZURE=OFF"
        "-DPYARROW_GCS=OFF"
        "-DPYARROW_S3=OFF"
        "-DPYARROW_HDFS=OFF"
        "-DPython3_INCLUDE_DIR=${py}/include/${py.libPrefix}"
        "-DPython3_NumPy_INCLUDE_DIR=${crossNumpyInc}"
      ];
    }
    pyprev.pyarrow
  )
