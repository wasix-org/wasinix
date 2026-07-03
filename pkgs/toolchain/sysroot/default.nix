# The from-source wasix sysroot, mirroring wasix-libc's build32-general.sh. Per
# ABI variant: build libc (the wasix-libc Makefile), compiler-rt, and
# libc++/libc++abi/libunwind (cmake driven by wasix-libc's committed
# clang-wasix*.cmake_toolchain files, which stay the single source of the ABI
# flags). Components are staged (libc, then +compiler-rt, then +libcxx) and
# merged into a per-variant sysroot. The combined `sysroot` has one subdir per
# variant (release-tarball layout); wasixcc points WASIXCC_SYSROOT_PREFIX here
# and selects the subdir by EH/PIC.
{
  pkgs,
  llvm,
  llvmVersion,
}: let
  inherit (pkgs) lib;
  # Profile table: one sysroot variant per profile, encoded as {eh, pic, exnref}
  # (PIC is only valid with EH).
  profilesCfg = import ../../profiles.nix;

  wasixLibcVersion = "v2026-07-03.1";
  wasixLibcSrc = pkgs.fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasix-libc";
    tag = wasixLibcVersion; # content hash pins it
    hash = "sha256-6xpQdtb3GjF9MnepHuZXxsdQssEP8m3ZK8MavLfFU2o=";
  };

  # The cmake toolchain file with this variant's ABI flags. PIC is a cmake arg,
  # not a separate file.
  toolchainFileFor = {
    eh,
    exnref,
  }:
    if !eh
    then "${wasixLibcSrc}/tools/clang-wasix.cmake_toolchain"
    else if exnref
    then "${wasixLibcSrc}/tools/clang-wasix-exnref-eh.cmake_toolchain"
    else "${wasixLibcSrc}/tools/clang-wasix-eh.cmake_toolchain";

  # Merge component output trees into one sysroot (mirrors build32's sysroot(),
  # which rsyncs them together). A real copy, not symlinkJoin: the components
  # install into the SAME dirs (lib/wasm32-wasi, include/) and cmake/clang resolve
  # --sysroot paths through the tree. --no-preserve=mode so later components can
  # merge into the read-only store copies.
  mkSysroot = sname: comps:
    pkgs.runCommand "wasix-sysroot-${sname}" {} (
      ''
        mkdir -p "$out"
      ''
      + lib.concatMapStrings (c: ''
        cp -r --no-preserve=mode,ownership ${c}/. "$out/"
      '')
      comps
    );

  # Shared by the compiler-rt/libcxx cmake builds: stdenvNoCC has no compiler env,
  # so export the tools the cmake hook and toolchain file read. The prefix-map
  # gives reproducible debug info (mirrors build32); computed in preConfigure
  # because it needs the source path ($PWD before the hook cd's into ./build) and
  # clang's resource dir.
  runtimesPreConfigure = ''
    export CC=clang CXX=clang++ NM=llvm-nm AR=llvm-ar RANLIB=llvm-ranlib STRIP=llvm-strip
    resource_dir="$(clang -print-resource-dir)"
    prefix_map="-ffile-prefix-map=$PWD=. -ffile-prefix-map=$resource_dir=/clang"
    cmakeFlagsArray+=(
      "-DCMAKE_C_FLAGS=$prefix_map"
      "-DCMAKE_CXX_FLAGS=$prefix_map"
      "-DCMAKE_ASM_FLAGS=$prefix_map"
    )
  '';

  mkVariant = {
    name,
    eh,
    pic,
    exnref,
  }: let
    toolchainFile = toolchainFileFor {inherit eh exnref;};

    libc = pkgs.callPackage ./libc.nix {
      inherit eh pic exnref;
      src = wasixLibcSrc;
      version = wasixLibcVersion;
    };

    # compiler-rt builds against a libc-only sysroot (build32 staging), from the
    # same LLVM tree the toolchain was built from.
    compiler-rt = pkgs.callPackage ./compiler-rt.nix {
      inherit name pic llvm toolchainFile runtimesPreConfigure;
      version = llvmVersion;
      sysroot = mkSysroot "${name}-rtdeps" [libc];
    };

    # libcxx builds against a sysroot of libc + compiler-rt (build32 staging).
    libcxx = pkgs.callPackage ./libcxx.nix {
      inherit name eh pic llvm toolchainFile runtimesPreConfigure;
      version = llvmVersion;
      sysroot = mkSysroot "${name}-cxxdeps" [libc compiler-rt];
    };

    # Subdir name under the combined sysroot, matching the release tarballs
    # (off: sysroot, eh: sysroot-eh, ehpic: sysroot-ehpic, ...).
    sysrootSubdir = profilesCfg.sysrootSubdirs.${name};

    sysroot = mkSysroot name [libc compiler-rt libcxx];

    # Compile smoke test against this sysroot.
    test = pkgs.callPackage ../tests/sysroot-test.nix {
      inherit name eh pic toolchainFile sysroot llvm;
    };
  in {
    inherit name eh pic exnref libc compiler-rt libcxx sysrootSubdir sysroot test;
  };

  # One variant per profile: `off` = threads without EH, `eh` adds C++ exceptions,
  # `pic` builds position-independent, `exnref` uses the exnref/SjLj exception model.
  variants =
    lib.mapAttrs (name: enc: mkVariant (enc // {inherit name;}))
    profilesCfg.sysrootEncodings;

  # Combined sysroot: one subdir per variant; WASIXCC_SYSROOT_PREFIX points here.
  sysroot = pkgs.runCommand "wasix-sysroot" {} (
    ''
      mkdir -p "$out"
    ''
    + lib.concatMapStrings (v: ''
      ln -s ${v.sysroot} "$out/${v.sysrootSubdir}"
    '') (lib.attrValues variants)
  );

  tests = lib.mapAttrs (_: v: v.test) variants;
in
  {
    inherit variants sysroot tests;
  }
  # Default single-variant component attrs = the `off` variant.
  // {inherit (variants.off) libc compiler-rt libcxx;}
