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
  final,
  pyprev,
  wasixPython,
  lib,
  helpers,
  ...
}: let
  wheels = import ../lib/wheels.nix {inherit lib;};
  py = wasixPython;
  crossNumpyInc = "${py.pkgs.numpy}/lib/${py.libPrefix}/site-packages/numpy/_core/include";
  # pyarrow IS an arrow-cpp release: nixpkgs takes `inherit (arrow-cpp) version
  # src`, both from the same apache/arrow tag. So a history pyarrow has to link
  # the same-versioned arrow-cpp mint, which packages/history.json carries.
  version = pyprev.pyarrow.version;
  isHistory = (pyprev.pyarrow.passthru.wasix.historySpec or null) != null;
  arrowCpp =
    if isHistory
    then final."arrow-cpp_${lib.replaceStrings ["."] ["_"] version}"
    else final.arrow-cpp;
  # 24 moved to scikit-build-core, which takes cmake args as -Ccmake.args (what
  # nixpkgs forwards `cmakeFlags` to) and reads the PYARROW_<NAME> cmake vars.
  # Older releases build through setup.py, which takes the same cmake args via
  # PYARROW_CMAKE_OPTIONS and selects components with PYARROW_WITH_* instead.
  preSkbuild = lib.versionOlder version "24";
  # cross facts cmake cannot probe: it would otherwise find the build python and
  # compile against native (64-bit long) headers, and arrow's SetupCxxFlags
  # fatals ("Unknown system processor") without ARROW_CPU_FLAG.
  crossCmakeArgs = [
    "-DARROW_CPU_FLAG=wasm32"
    "-DARROW_SIMD_LEVEL=NONE"
    "-DARROW_RUNTIME_SIMD_LEVEL=NONE"
    "-DPython3_INCLUDE_DIR=${py}/include/${py.libPrefix}"
    "-DPython3_NumPy_INCLUDE_DIR=${crossNumpyInc}"
  ];
in
  wheels.onlyOnWasix pyprev.pyarrow (
    helpers.libTweaks ({
        patches = [./patches/pyarrow-static-arrow-wasix.patch];
        # libcst is a build-system req only for scripts/update_stub_docstrings.py (a maintenance
        # script a wheel build never runs); nixpkgs pulls a *native* libcst that fails under the
        # shared setuptools-rust hook (rustc has no wasm32-wasmer-wasi-dl target). Drop it from the
        # inputs (so the native wheel isn't pulled) and from pyproject's requires (else
        # `build --no-isolation` errors "Missing dependencies: libcst").
        nativeBuildInputs = ni: builtins.filter (p: !(lib.hasInfix "libcst" (toString (p.name or p.pname or "")))) ni;
        # only 24 declares it; older releases have nothing to drop
        postPatch = lib.optionalString (!preSkbuild) ''
          substituteInPlace pyproject.toml --replace-fail '"libcst>=1.8.6",' ""
        '';
        # all modules (cython .so + libarrow_python.so) land in site-packages/pyarrow; wasmer
        # resolves the NEEDED libarrow_python.so via the dylink RUNPATH ($ORIGIN is supported).
        env = {NIX_LDFLAGS = "--rpath=$ORIGIN";};
      }
      // (
        if preSkbuild
        then {
          # setup.py path: same cmake args, different door. Components come from
          # PYARROW_WITH_* (nixpkgs turns dataset/hdfs/encryption on for a full
          # arrow; ours is the minimal build, so turn them back off). arrow-cpp
          # reaches the link through buildInputs AND propagation, so swap both or
          # the current arrow's -L rides along beside the paired one.
          buildInputs = old: [arrowCpp] ++ builtins.filter (b: !(lib.hasInfix "arrow-cpp" (toString (b.name or "")))) old;
          propagatedBuildInputs = old: [arrowCpp] ++ builtins.filter (b: !(lib.hasInfix "arrow-cpp" (toString (b.name or "")))) old;
          env = {
            PYARROW_CMAKE_OPTIONS = toString (crossCmakeArgs ++ ["-DCMAKE_INSTALL_RPATH=${arrowCpp}/lib"]);
            ARROW_HOME = "${arrowCpp}";
            PARQUET_HOME = "${arrowCpp}";
            PYARROW_WITH_DATASET = "0";
            PYARROW_WITH_HDFS = "0";
            PYARROW_WITH_PARQUET_ENCRYPTION = "0";
          };
        }
        else {
          # scikit-build-core path: nixpkgs forwards cmakeFlags as -Ccmake.args.
          # parquet is on (arrow-cpp.nix builds it); the other integrations aren't in the minimal
          # arrow-cpp, so force them off. CMakeLists' define_option leaves each PYARROW_<NAME> at
          # "AUTO" and would otherwise honour nixpkgs' PYARROW_WITH_<NAME>=1 env (dataset/hdfs) and
          # fatal against our arrow.
          cmakeFlags =
            crossCmakeArgs
            ++ [
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
            ];
        }
      ))
    pyprev.pyarrow
  )
