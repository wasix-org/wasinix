# pyarrow links enabled arrow-cpp components into libarrow_python.so. Releases
# before 24 use setup.py environment variables; newer releases use
# scikit-build-core CMake flags. Both need explicit cross Python/NumPy headers.
{
  final,
  pyfinal,
  pyprev,
  wasixPython,
  lib,
  helpers,
  ...
}: let
  py = wasixPython;
  crossNumpyInc = py.pkgs.numpy.crossInclude;
  # pyarrow IS an arrow-cpp release: nixpkgs takes `inherit (arrow-cpp) version
  # src`, both from the same apache/arrow tag. So a history pyarrow has to link
  # the same-versioned arrow-cpp mint, which wasix/history.json carries.
  version = pyprev.pyarrow.version;
  isHistory = (pyprev.pyarrow.passthru.wasix.historySpec or null) != null;
  arrowCpp =
    if isHistory
    then final."arrow-cpp_${lib.replaceStrings ["."] ["_"] version}"
    else final.arrow-cpp;
  # Before 24, setup.py reads PYARROW_CMAKE_OPTIONS and PYARROW_WITH_*.
  # Newer releases read the equivalent CMake variables.
  preSkbuild = lib.versionOlder version "24";
  # cross facts cmake cannot probe: it would otherwise find the build python and
  # compile against native (64-bit long) headers, and arrow's SetupCxxFlags
  # fatals ("Unknown system processor") without ARROW_CPU_FLAG.
  crossCmakeArgs = [
    "-DARROW_CPU_FLAG=wasm32"
    "-DARROW_SIMD_LEVEL=NONE"
    "-DARROW_RUNTIME_SIMD_LEVEL=NONE"
    "-DPython3_INCLUDE_DIR=${py.crossIncludeDir}"
    "-DPython3_NumPy_INCLUDE_DIR=${crossNumpyInc}"
  ];
in
  helpers.extendPackage pyprev.pyarrow ({
      patches = [./patches/pyarrow-static-arrow-wasix.patch];
      # No suite: the extension fails to load its arrow C++
      # ("arrow::compute::Initialize" unresolved), dying at collection;
      # WASIX-TODO.md tracks the dylib symbol-resolution defect.
      passthru.wasinix.checks.captured.install = false;
      # PyArrow uses libcst only in a maintenance script; its native Rust build
      # cannot target wasm32-wasmer-wasi-dl. Remove it from inputs and pyproject.
      nativeBuildInputs = helpers.dropInputsByNameInfix ["libcst"];
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
        # arrow-cpp reaches the link through both input lists, so replacing
        # only one leaves both versions' library search paths.
        buildInputs = old: [arrowCpp] ++ helpers.dropInputsByNameInfix ["arrow-cpp"] old;
        propagatedBuildInputs = old: [arrowCpp] ++ helpers.dropInputsByNameInfix ["arrow-cpp"] old;
        # The build-host importlib.metadata cannot resolve a cross-layout version.
        dontCheckPythonMetadata = true;
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
        # Explicit values prevent nixpkgs' PYARROW_WITH_* environment from
        # selecting components that arrow-cpp does not provide.
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
