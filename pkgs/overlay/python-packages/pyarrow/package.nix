# pyarrow for wasix, over the static arrow-cpp. wasm has no shared
# libarrow, so the patch whole-archives libarrow.a and libparquet.a into
# libarrow_python.so, exporting every symbol the cython modules need.
{
  final,
  pyprev,
  wasixPython,
  lib,
  helpers,
  ...
}: let
  py = wasixPython;
  crossNumpyInc = py.pkgs.numpy.crossInclude;
  # pyarrow and arrow-cpp share one apache/arrow tag, so a history pyarrow must
  # link the same-versioned arrow-cpp.
  version = pyprev.pyarrow.version;
  isHistory = (pyprev.pyarrow.passthru.wasix.historySpec or null) != null;
  arrowCpp =
    if isHistory
    then final."arrow-cpp_${lib.replaceStrings ["."] ["_"] version}"
    else final.arrow-cpp;
  # 24 takes cmake args as -Ccmake.args (where nixpkgs forwards cmakeFlags) and
  # components as PYARROW_<NAME>; older releases go through setup.py's env vars.
  preSkbuild = lib.versionOlder version "24";
  # Cross facts cmake cannot probe: it would find the build python's 64-bit
  # headers, and SetupCxxFlags fatals "Unknown system processor" without a CPU flag.
  crossCmakeArgs = [
    "-DARROW_CPU_FLAG=wasm32"
    "-DARROW_SIMD_LEVEL=NONE"
    "-DARROW_RUNTIME_SIMD_LEVEL=NONE"
    "-DPython3_INCLUDE_DIR=${py.crossIncludeDir}"
    "-DPython3_NumPy_INCLUDE_DIR=${crossNumpyInc}"
  ];
in
  helpers.libTweaks ({
      patches = [./patches/pyarrow-static-arrow-wasix.patch];
      # libcst fails under the shared setuptools-rust hook (no
      # wasm32-wasmer-wasi-dl target); pyarrow declares it only for a dev script.
      nativeBuildInputs = helpers.dropInputsByNameInfix ["libcst"];
      # Only 24 requires it, and `build --no-isolation` reads that requires list.
      postPatch = lib.optionalString (!preSkbuild) ''
        substituteInPlace pyproject.toml --replace-fail '"libcst>=1.8.6",' ""
      '';
      # wasmer resolves the NEEDED libarrow_python.so through the dylink RUNPATH.
      env = {NIX_LDFLAGS = "--rpath=$ORIGIN";};
    }
    // (
      if preSkbuild
      then {
        # The build-host importlib.metadata cannot resolve a cross-layout version.
        dontCheckPythonMetadata = true;
        # arrow-cpp reaches the link through both input lists, so a swap of one
        # leaves two arrow -Ls.
        buildInputs = old: [arrowCpp] ++ helpers.dropInputsByNameInfix ["arrow-cpp"] old;
        propagatedBuildInputs = old: [arrowCpp] ++ helpers.dropInputsByNameInfix ["arrow-cpp"] old;
        env = {
          PYARROW_CMAKE_OPTIONS = toString (crossCmakeArgs ++ ["-DCMAKE_INSTALL_RPATH=${arrowCpp}/lib"]);
          ARROW_HOME = "${arrowCpp}";
          PARQUET_HOME = "${arrowCpp}";
          PYARROW_WITH_DATASET = "1";
          PYARROW_WITH_HDFS = "0";
          PYARROW_WITH_PARQUET_ENCRYPTION = "1";
        };
      }
      else {
        # Keep components aligned with the static arrow-cpp feature set.
        cmakeFlags =
          crossCmakeArgs
          ++ [
            "-DPYARROW_PARQUET=ON"
            "-DPYARROW_DATASET=ON"
            "-DPYARROW_ACERO=ON"
            "-DPYARROW_PARQUET_ENCRYPTION=ON"
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
