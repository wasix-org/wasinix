# flang_rt.runtime for wasix: an llvm-project runtimes build driven by wasix-libc's
# clang-wasix*.cmake_toolchain, plus the host flang for the lone Fortran source.
{
  lib,
  stdenvNoCC,
  cmake,
  ninja,
  python3,
  llvm,
  flang,
  version,
  toolchainFile,
  sysroot,
  runtimesPreConfigure,
  name,
  pic ? false,
}: let
  flangCross = import ../../toolchain/flang-cross.nix {inherit lib;};
in
  stdenvNoCC.mkDerivation {
    __structuredAttrs = true;

    pname = "wasix-flang-rt-${name}";
    inherit version;
    src = llvm.llvm.monorepoSrc;

    nativeBuildInputs = [
      cmake
      ninja
      python3
      llvm.clang-unwrapped
      llvm.lld
      llvm.llvm
      flang
    ];

    # Async EXECUTE_COMMAND_LINE forks unconditionally on non-Windows; wasix-libc
    # hides fork() under Wasm-EH and there is no shell to exec (WASIX-TODO.md).
    patches = [./flang-rt-execute-no-fork-on-wasi.patch];

    cmakeDir = "../runtimes";
    cmakeBuildType = "RelWithDebInfo";

    cmakeFlags =
      [
        (lib.cmakeFeature "CMAKE_TOOLCHAIN_FILE" toolchainFile)
        (lib.cmakeFeature "CMAKE_SYSROOT" "${sysroot}")
        (lib.cmakeFeature "LLVM_ENABLE_RUNTIMES" "flang-rt")
        # The resource-dir arch subdir otherwise comes from the host triple. The
        # runtimes CMakeLists copies LLVM_TARGET_TRIPLE from this, so this is the knob.
        (lib.cmakeFeature "LLVM_DEFAULT_TARGET_TRIPLE" "wasm32-wasmer-wasi")
        # The toolchain file only knows C/C++/ASM, so Fortran is pinned here.
        (lib.cmakeFeature "CMAKE_Fortran_FLAGS" (flangCross.mkFortranFlags {inherit pic;}))
        (lib.cmakeBool "CMAKE_C_COMPILER_WORKS" true)
        (lib.cmakeBool "CMAKE_CXX_COMPILER_WORKS" true)
        (lib.cmakeBool "CMAKE_C_LINKER_DEPFILE_SUPPORTED" false)
        (lib.cmakeBool "CMAKE_CXX_LINKER_DEPFILE_SUPPORTED" false)
        (lib.cmakeBool "LLVM_COMPILER_CHECKED" true)
        (lib.cmakeBool "UNIX" true)
        # The shared library needs a working target link during the runtimes build.
        (lib.cmakeBool "FLANG_RT_ENABLE_STATIC" true)
        (lib.cmakeBool "FLANG_RT_ENABLE_SHARED" false)
        (lib.cmakeBool "FLANG_RT_INCLUDE_TESTS" false)
        (lib.cmakeFeature "FLANG_RT_LIBC_PROVIDER" "system")
        (lib.cmakeFeature "FLANG_RT_LIBCXX_PROVIDER" "system")
        (lib.cmakeBool "CMAKE_POSITION_INDEPENDENT_CODE" pic)
      ]
      ++ flangCross.mkFortranProbeVars {inherit flang version;};

    # flang-rt narrows uint64_t byte sizes into size_t in braced initializers,
    # ill-formed at 32-bit size_t but lossless within the 4 GiB wasm address space.
    preConfigure =
      runtimesPreConfigure
      + ''
        cmakeFlagsArray+=("-DCMAKE_CXX_FLAGS=$prefix_map -Wno-c++11-narrowing")
      '';

    # The build installs into the clang resource dir; consumers link against the
    # sysroot-shaped lib/wasm32-wasi path, which the setup hook adds to their link.
    postInstall = ''
      lib="$(find "$out" -name 'libflang_rt.runtime.a' | head -n1)"
      if [ -z "$lib" ]; then echo "flang-rt: libflang_rt.runtime.a not produced"; find "$out" -type f; exit 1; fi
      install -Dm644 "$lib" "$out/lib/wasm32-wasi/libflang_rt.runtime.a"

      mkdir -p "$out/nix-support"
      substitute ${./flang-rt-setup-hook.sh} "$out/nix-support/setup-hook" \
        --subst-var-by libdir "$out/lib/wasm32-wasi"
    '';

    meta = with lib; {
      description = "LLVM Fortran runtime (flang_rt.runtime) for WASIX (${name} variant), built from source";
      homepage = "https://github.com/wasix-org/llvm-project";
      license = with licenses; [asl20 mit];
      platforms = platforms.unix;
    };
  }
