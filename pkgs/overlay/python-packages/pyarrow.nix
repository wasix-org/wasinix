# pyarrow for wasix, over the minimal static arrow-cpp (see
# overlay/packages/arrow-cpp.nix): parquet but no dataset/orc/flight/cloud-fs
# extensions, all of arrow linked into libarrow_python.so (wasm has no shared
# libarrow). The patch --whole-archives libarrow.a + libparquet.a into
# libarrow_python.so so every symbol is exported for the cython modules.
# setup.py drives its
# own cmake (dontUseCmakeConfigure), so the cross identity and the wasix
# python/numpy headers are injected via PYARROW_CMAKE_OPTIONS: cmake would
# otherwise probe the build python and compile against native (64-bit long)
# headers.
{
  pyprev,
  final,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
  py = final.python3;
  crossNumpyInc = "${py.pkgs.numpy}/lib/${py.libPrefix}/site-packages/numpy/_core/include";
in
  wheels.onlyOnWasix pyprev.pyarrow (
    helpers.libTweaks {
      patches = [./patches/pyarrow-static-arrow-wasix.patch];
      env = {
        # all modules (cython .so + libarrow_python.so) land in
        # site-packages/pyarrow; wasmer resolves the NEEDED libarrow_python.so
        # via the dylink RUNPATH ($ORIGIN is supported by its loader).
        NIX_LDFLAGS = "--rpath=$ORIGIN";
        PYARROW_WITH_DATASET = 0;
        PYARROW_WITH_HDFS = 0;
        PYARROW_WITH_PARQUET = 1;
        PYARROW_WITH_PARQUET_ENCRYPTION = 0;
        PYARROW_CMAKE_OPTIONS = toString [
          "-DCMAKE_SYSTEM_NAME=Wasi"
          "-DCMAKE_SYSTEM_PROCESSOR=wasm32"
          "-DARROW_CPU_FLAG=wasm32"
          "-DARROW_SIMD_LEVEL=NONE"
          "-DARROW_RUNTIME_SIMD_LEVEL=NONE"
          "-DPython3_INCLUDE_DIR=${py}/include/${py.libPrefix}"
          "-DPython3_NumPy_INCLUDE_DIR=${crossNumpyInc}"
        ];
      };
    }
    pyprev.pyarrow
  )
