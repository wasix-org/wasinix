# libomp for wasix, riding upstream libomp's own wasm32/wasi port (KMP_ARCH_WASM +
# KMP_OS_WASI). Standalone openmp build against the staged sysroot.
{
  lib,
  stdenvNoCC,
  cmake,
  ninja,
  python3,
  llvm,
  version,
  toolchainFile,
  sysroot,
  runtimesPreConfigure,
  name,
  pic ? false,
}:
stdenvNoCC.mkDerivation {
  __structuredAttrs = true;

  pname = "wasix-openmp-${name}";
  inherit version;
  src = llvm.llvm.monorepoSrc;

  # wasm has no dynamic-arity call, so __kmp_invoke_microtask switches on argc, and
  # upstream stops at 15: a wider region aborts with "Too many args to microtask".
  patches = [./openmp-wasm-microtask-args.patch];

  nativeBuildInputs = [
    cmake
    ninja
    python3
    llvm.clang-unwrapped
    llvm.lld
    llvm.llvm
  ];

  # CMAKE_SOURCE_DIR == the openmp dir makes OPENMP_STANDALONE_BUILD auto-true. The
  # LLVM_ENABLE_RUNTIMES path puts omp.h where the external fork clang cannot find it.
  cmakeDir = "../openmp";
  cmakeBuildType = "Release";

  cmakeFlags = [
    (lib.cmakeFeature "CMAKE_TOOLCHAIN_FILE" toolchainFile)
    (lib.cmakeFeature "CMAKE_SYSROOT" "${sysroot}")
    # config-ix and the flag logic read UNIX, which WASI's CMAKE_SYSTEM_NAME leaves unset.
    (lib.cmakeBool "UNIX" true)
    # Selects libomp's wasm path: static-only, C microtask invoke, no arch asm.
    (lib.cmakeFeature "LIBOMP_ARCH" "wasm32")
    (lib.cmakeBool "LIBOMP_ENABLE_SHARED" false)
    # archer and ompd are unconditionally add_library(SHARED), which this static
    # build cannot produce; archer is TSan-based and libomptarget needs a device.
    (lib.cmakeBool "LIBOMP_OMPD_SUPPORT" false)
    (lib.cmakeBool "OPENMP_ENABLE_OMPT_TOOLS" false)
    (lib.cmakeBool "OPENMP_ENABLE_LIBOMPTARGET" false)
    # The compiler probes link a wasm executable, which raw clang plus the bare
    # toolchain file cannot do: wasixcc supplies the crt/compiler-rt at consume time.
    (lib.cmakeBool "CMAKE_C_COMPILER_WORKS" true)
    (lib.cmakeBool "CMAKE_CXX_COMPILER_WORKS" true)
    (lib.cmakeBool "CMAKE_ASM_COMPILER_WORKS" true)
    (lib.cmakeBool "CMAKE_C_LINKER_DEPFILE_SUPPORTED" false)
    (lib.cmakeBool "CMAKE_CXX_LINKER_DEPFILE_SUPPORTED" false)
    (lib.cmakeBool "LLVM_COMPILER_CHECKED" true)
    (lib.cmakeBool "CMAKE_POSITION_INDEPENDENT_CODE" pic)
  ];

  preConfigure = runtimesPreConfigure;

  # The standalone install lands libomp.a in lib/; consumers link against the
  # sysroot-shaped lib/wasm32-wasi/ path.
  postInstall = ''
    lib="$(find "$out" -name 'libomp.a' | head -n1)"
    if [ -z "$lib" ]; then echo "openmp: libomp.a not produced"; find "$out" -type f; exit 1; fi
    install -Dm644 "$lib" "$out/lib/wasm32-wasi/libomp.a"
    if [ ! -e "$out/include/omp.h" ]; then
      hdr="$(find "$out" -name 'omp.h' | head -n1)"
      [ -n "$hdr" ] && install -Dm644 "$hdr" "$out/include/omp.h"
    fi
  '';

  meta = with lib; {
    description = "LLVM OpenMP host runtime (libomp) for WASIX (${name} variant), built from source";
    longDescription = "The LLVM OpenMP host runtime for WASIX ${name} targets, built from the WASIX LLVM source tree.";
    homepage = "https://github.com/wasix-org/llvm-project";
    changelog = "https://github.com/wasix-org/llvm-project/releases/tag/${version}";
    license = with licenses; [mit ncsa];
    platforms = platforms.unix;
  };
}
