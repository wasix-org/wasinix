# compiler-rt builtins for wasix, built the upstream way: cmake of
# llvm-project/compiler-rt driven by wasix-libc's committed clang-wasix*.cmake_toolchain
# (the single source of truth for the ABI flags). Mirrors build32-general.sh:compiler_rt().
#
# Uses the standard nixpkgs cmake hook (stdenvNoCC so there's no host cc to fight;
# the toolchain file owns the compiler, we just export the tools the hook wires up).
# Output is sysroot-shaped: lib/wasm32-wasi/libclang_rt.builtins-wasm32.a.
{
  lib,
  stdenvNoCC,
  cmake,
  ninja,
  python3,
  # the fork LLVM (clang/lld/llvm tools). Its `.llvm.monorepoSrc` is the monorepo
  # checkout we build compiler-rt from — same tree the toolchain came from.
  llvm,
  version,
  # the wasix-libc cmake toolchain file for this variant (selected in default.nix).
  toolchainFile,
  # staged sysroot to build against (libc only, per build32).
  sysroot,
  # compiler env + reproducible prefix-map cmake flags (shared with libcxx.nix,
  # defined in ./default.nix).
  runtimesPreConfigure,
  name,
  pic ? false,
}:
stdenvNoCC.mkDerivation {
  __structuredAttrs = true;

  pname = "wasix-compiler-rt-${name}";
  inherit version;
  src = llvm.llvm.monorepoSrc;

  nativeBuildInputs = [
    cmake
    ninja
    python3
    llvm.clang-unwrapped
    llvm.lld
    llvm.llvm
  ];

  # Build the compiler-rt subproject out-of-source (hook cd's into ./build).
  cmakeDir = "../compiler-rt";
  cmakeBuildType = "RelWithDebInfo";

  cmakeFlags = [
    (lib.cmakeFeature "CMAKE_SYSTEM_NAME" "WASI")
    (lib.cmakeFeature "CMAKE_SYSTEM_VERSION" "1")
    (lib.cmakeFeature "CMAKE_SYSTEM_PROCESSOR" "wasm32")
    (lib.cmakeFeature "CMAKE_C_COMPILER_TARGET" "wasm32-wasi")
    (lib.cmakeFeature "COMPILER_RT_OS_DIR" "wasm32-wasi")
    (lib.cmakeFeature "CMAKE_TOOLCHAIN_FILE" toolchainFile)
    (lib.cmakeFeature "CMAKE_SYSROOT" "${sysroot}")
    (lib.cmakeBool "CMAKE_C_COMPILER_WORKS" true)
    (lib.cmakeBool "CMAKE_CXX_COMPILER_WORKS" true)
    (lib.cmakeBool "CMAKE_C_LINKER_DEPFILE_SUPPORTED" false)
    (lib.cmakeBool "CMAKE_CXX_LINKER_DEPFILE_SUPPORTED" false)
    (lib.cmakeBool "COMPILER_RT_BAREMETAL_BUILD" true)
    (lib.cmakeBool "COMPILER_RT_BUILD_XRAY" false)
    (lib.cmakeBool "COMPILER_RT_INCLUDE_TESTS" false)
    (lib.cmakeBool "COMPILER_RT_HAS_FPIC_FLAG" pic)
    (lib.cmakeBool "COMPILER_RT_DEFAULT_TARGET_ONLY" true)
    (lib.cmakeBool "COMPILER_RT_BUILD_SANITIZERS" false)
    (lib.cmakeBool "COMPILER_RT_BUILD_LIBFUZZER" false)
    (lib.cmakeBool "COMPILER_RT_BUILD_PROFILE" true)
    (lib.cmakeBool "COMPILER_RT_BUILD_CTX_PROFILE" false)
    (lib.cmakeBool "COMPILER_RT_BUILD_MEMPROF" false)
    (lib.cmakeBool "COMPILER_RT_BUILD_ORC" false)
    (lib.cmakeBool "COMPILER_RT_BUILD_GWP_ASAN" false)
    (lib.cmakeBool "COMPILER_RT_USE_LLVM_UNWINDER" false)
    (lib.cmakeBool "COMPILER_RT_BUILTINS_ENABLE_PIC" pic)
    (lib.cmakeBool "SANITIZER_USE_STATIC_LLVM_UNWINDER" false)
    (lib.cmakeBool "COMPILER_RT_ENABLE_STATIC_UNWINDER" false)
    (lib.cmakeBool "HAVE_UNWIND_H" false)
    (lib.cmakeBool "COMPILER_RT_HAS_FUNWIND_TABLES_FLAG" false)
    (lib.cmakeBool "UNIX" true)
  ];

  preConfigure = runtimesPreConfigure;

  postInstall = ''
    llvm-ranlib "$out/lib/wasm32-wasi/libclang_rt.builtins-wasm32.a"
  '';

  meta = with lib; {
    description = "compiler-rt builtins for WASIX (${name} variant), built from source";
    homepage = "https://github.com/wasix-org/wasix-libc";
    license = with licenses; [asl20 mit];
    platforms = platforms.unix;
  };
}
