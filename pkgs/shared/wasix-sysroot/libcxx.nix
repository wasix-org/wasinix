# libc++ / libc++abi (+ libunwind for EH variants) for wasix: cmake of
# llvm-project/runtimes driven by wasix-libc's clang-wasix*.cmake_toolchain,
# mirroring build32-general.sh:libcxx(). Output is sysroot-shaped:
# lib/wasm32-wasi/{libc++.a,libc++abi.a,libunwind.a,...} + include/c++/v1/.
{
  lib,
  stdenvNoCC,
  cmake,
  ninja,
  python3,
  # the fork LLVM; its .llvm.monorepoSrc is the tree we build the runtimes from
  # (the same one the toolchain came from).
  llvm,
  version,
  # per-variant wasix-libc cmake toolchain file (selected in default.nix).
  toolchainFile,
  # staged sysroot to build against (libc + compiler-rt, per build32).
  sysroot,
  # compiler env + prefix-map cmake flags, shared with compiler-rt.nix (see ./package.nix).
  runtimesPreConfigure,
  name,
  eh ? false,
  pic ? false,
}: let
  # EH variants build libunwind in-tree as a runtime, as build32 does.
  runtimes =
    if eh
    then "libcxx;libcxxabi;libunwind"
    else "libcxx;libcxxabi";
in
  stdenvNoCC.mkDerivation {
    __structuredAttrs = true;

    pname = "wasix-libcxx-${name}";
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

    cmakeDir = "../runtimes";
    cmakeBuildType = "RelWithDebInfo";

    cmakeFlags = [
      (lib.cmakeFeature "CMAKE_TOOLCHAIN_FILE" toolchainFile)
      (lib.cmakeFeature "CMAKE_SYSROOT" "${sysroot}")
      (lib.cmakeFeature "LLVM_ENABLE_RUNTIMES" runtimes)
      (lib.cmakeFeature "LIBCXX_LIBDIR_SUFFIX" "/wasm32-wasi")
      (lib.cmakeFeature "LIBCXXABI_LIBDIR_SUFFIX" "/wasm32-wasi")
      (lib.cmakeFeature "LLVM_LIBDIR_SUFFIX" "/wasm32-wasi")
      (lib.cmakeFeature "LIBCXX_CXX_ABI" "libcxxabi")
      (lib.cmakeFeature "LIBCXX_ABI_VERSION" "2")
      (lib.cmakeBool "CMAKE_C_COMPILER_WORKS" true)
      (lib.cmakeBool "CMAKE_CXX_COMPILER_WORKS" true)
      (lib.cmakeBool "LLVM_COMPILER_CHECKED" true)
      (lib.cmakeBool "UNIX" true)
      # threaded wasix libc++ (pthread-backed) with a real filesystem + musl libc.
      (lib.cmakeBool "LIBCXX_ENABLE_THREADS" true)
      (lib.cmakeBool "LIBCXX_HAS_PTHREAD_API" true)
      (lib.cmakeBool "LIBCXX_HAS_EXTERNAL_THREAD_API" false)
      (lib.cmakeBool "LIBCXX_HAS_WIN32_THREAD_API" false)
      (lib.cmakeBool "LIBCXX_ENABLE_SHARED" false)
      (lib.cmakeBool "LIBCXX_ENABLE_FILESYSTEM" true)
      (lib.cmakeBool "LIBCXX_HAS_MUSL_LIBC" true)
      (lib.cmakeBool "LIBCXX_USE_COMPILER_RT" true)
      (lib.cmakeBool "LIBCXXABI_ENABLE_SHARED" false)
      (lib.cmakeBool "LIBCXXABI_SILENT_TERMINATE" true)
      (lib.cmakeBool "LIBCXXABI_ENABLE_THREADS" true)
      (lib.cmakeBool "LIBCXXABI_HAS_PTHREAD_API" true)
      (lib.cmakeBool "LIBCXXABI_HAS_EXTERNAL_THREAD_API" false)
      (lib.cmakeBool "LIBCXXABI_HAS_WIN32_THREAD_API" false)
      # exceptions + the LLVM unwinder are EH-only.
      (lib.cmakeBool "LIBCXX_ENABLE_EXCEPTIONS" eh)
      (lib.cmakeBool "LIBCXXABI_ENABLE_EXCEPTIONS" eh)
      (lib.cmakeBool "LIBCXXABI_USE_LLVM_UNWINDER" eh)
      (lib.cmakeBool "LIBUNWIND_ENABLE_SHARED" false)
      (lib.cmakeBool "LIBUNWIND_ENABLE_STATIC" eh)
      (lib.cmakeBool "LIBUNWIND_USE_COMPILER_RT" eh)
      (lib.cmakeBool "LIBUNWIND_ENABLE_THREADS" eh)
      (lib.cmakeBool "LIBUNWIND_HAS_PTHREAD_LIB" eh)
      (lib.cmakeBool "LIBUNWIND_INSTALL_LIBRARY" eh)
      # PIC: global-dynamic TLS comes from the patched toolchain file (see ./package.nix).
      (lib.cmakeBool "CMAKE_POSITION_INDEPENDENT_CODE" pic)
      (lib.cmakeBool "LLVM_ENABLE_PIC" pic)
    ];

    preConfigure = runtimesPreConfigure;

    meta = with lib; {
      description = "libc++/libc++abi for WASIX (${name} variant), built from source";
      longDescription = "The LLVM libc++ and libc++abi C++ standard libraries for WASIX ${name} targets, built from the WASIX LLVM source tree.";
      homepage = "https://github.com/wasix-org/llvm-project";
      changelog = "https://github.com/wasix-org/llvm-project/releases/tag/${version}";
      license = with licenses; [asl20 ncsa mit];
      platforms = platforms.unix;
    };
  }
