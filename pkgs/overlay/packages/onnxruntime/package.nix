# The C++ inference engine, rebuilt per interpreter by python-packages/onnxruntime.nix.
{
  prev,
  final,
  helpers,
  ...
}: let
  lib = final.lib;
in
  helpers.libTweaks {
    # onnx, the proto dependency, is declared PIC-only.
    passthru.wasix.supportedProfiles = helpers.profiles.pic;

    patches = [
      ./patches/onnxruntime-wasi-no-providers-shared.patch
      ./patches/onnxruntime-wasi-threadpool-emscripten.patch
      ./patches/onnxruntime-wasi-mlas-wasm-simd.patch
      ./patches/onnxruntime-wasi-no-dladdr.patch
    ];

    # These files read bare __wasm__ as emscripten and load external data via JS.
    postPatch = old:
      old
      + ''
        for f in onnxruntime/core/framework/external_data_loader.h \
                 onnxruntime/core/framework/external_data_loader.cc \
                 onnxruntime/core/framework/tensorprotoutils.cc \
                 onnxruntime/core/graph/model.cc; do
          substituteInPlace "$f" --replace-fail '__wasm__' '__EMSCRIPTEN__'
        done
      '';

    cmakeFlags = old: let
      # cmake/CMakeLists.txt hard-errors on the standalone training APIs when the
      # bindings are on: "Please use the --enable_training flag instead".
      pythonBindings = lib.elem (lib.cmakeBool "onnxruntime_ENABLE_PYTHON" true) old;
    in
      old
      ++ [
        # Exclusive with the static archives the pybind module links.
        (lib.cmakeBool "onnxruntime_BUILD_SHARED_LIB" false)
        # LTO emits bitcode archives, which carry no target_features section, so
        # abiCheck reports "exception-handling feature missing" for every object.
        (lib.cmakeBool "onnxruntime_ENABLE_LTO" false)
        # cpuinfo is x86/ARM CPUID probing with no wasm backend.
        (lib.cmakeBool "onnxruntime_ENABLE_CPUINFO" false)
        (lib.cmakeBool "onnxruntime_ENABLE_TRAINING_APIS" (!pythonBindings))

        # iconv is in libc.a; FindIconv's probe is a cross try_compile that can't link.
        (lib.cmakeBool "Iconv_IS_BUILT_IN" true)

        # mlas.h keys MLAS_TARGET_WASM_* off the toolchain's -msimd128 -mrelaxed-simd.
        (lib.cmakeBool "onnxruntime_ENABLE_WEBASSEMBLY_SIMD" true)
        (lib.cmakeBool "onnxruntime_ENABLE_WEBASSEMBLY_RELAXED_SIMD" true)
      ];
  }
  (prev.onnxruntime.override {
    cudaSupport = false;
    ncclSupport = false;
    rocmSupport = false;
    coremlSupport = false;
    openvinoSupport = false;
    # nixpkgs sets meta.broken = withFullProtobuf (duplicate onnx-ml.proto).
    withFullProtobuf = false;
    pythonSupport = false;
  })
