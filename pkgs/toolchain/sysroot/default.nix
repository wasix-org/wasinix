# The from-source wasix sysroot, built upstream-faithfully: mirror wasix-libc's
# build32-general.sh. Per ABI variant, build libc (the wasix-libc Makefile) +
# compiler-rt + libc++/libc++abi/libunwind (direct cmake driven by wasix-libc's
# committed clang-wasix*.cmake_toolchain files — so those files stay the single
# source of truth for the ABI flags, with no re-derivation in Nix). Each variant
# stages (libc → +compiler-rt → +libcxx) and merges into a sysroot, exactly like
# build32. The combined `sysroot` is a prefix dir with one subdir per variant
# (release-tarball layout); wasixcc points WASIXCC_SYSROOT_PREFIX here and selects
# the subdir by EH/PIC.
{
  pkgs,
  llvm,
  llvmVersion,
}: let
  inherit (pkgs) lib;
  # The canonical profile table: one sysroot variant per profile, selected by the
  # {eh, pic, exnref} encoding derived there (PIC is only valid with EH).
  profilesCfg = import ../../profiles.nix;

  wasixLibcVersion = "v2026-06-25.1";
  wasixLibcSrc = pkgs.applyPatches {
    name = "wasix-libc-${wasixLibcVersion}-patched";
    src = pkgs.fetchFromGitHub {
      owner = "wasix-org";
      repo = "wasix-libc";
      tag = wasixLibcVersion; # content hash pins it
      hash = "sha256-f0AavtFFyeTwOOJKX9EwxMxRW1fK2NGAEJdoY81DA8o=";
    };
    # PIC sysroot libc++ needs global-dynamic TLS; upstream PR pending.
    patches = [./wasix-libc-pic-tls.patch];
  };

  # The committed cmake toolchain file carrying this variant's ABI flags. PIC is
  # orthogonal (a cmake arg), so it doesn't select a different file.
  toolchainFileFor = {
    eh,
    exnref,
  }:
    if !eh
    then "${wasixLibcSrc}/tools/clang-wasix.cmake_toolchain"
    else if exnref
    then "${wasixLibcSrc}/tools/clang-wasix-exnref-eh.cmake_toolchain"
    else "${wasixLibcSrc}/tools/clang-wasix-eh.cmake_toolchain";

  # Merge the (sysroot-shaped) component output trees into one — used for the
  # staged build-sysroots and the final per-variant sysroot. Mirrors build32's
  # sysroot(), which rsyncs whole component outputs together (each component's own
  # build guarantees its contents). --no-preserve=mode so the read-only store files
  # become writable and later components can merge into the same dirs. A real
  # copy, not symlinkJoin: the components install into the SAME directories
  # (lib/wasm32-wasi, include/) and cmake/clang resolve --sysroot paths through
  # the tree, so we want one plain dir, not a forest of store symlinks.
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

  # Shared by the compiler-rt/libcxx cmake builds (stdenvNoCC has no compiler
  # env; the hook wires CMAKE_{C,CXX}_COMPILER/AR/… from these, and the variant
  # toolchain file reads $CC). Reproducible debug info via prefix-map (mirrors
  # build32) — computed in preConfigure because it needs the source path ($PWD,
  # before the cmake hook descends into ./build) and clang's resource dir.
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

    # compiler-rt builds against a sysroot of just libc (build32 staging). Its LLVM
    # source comes from `llvm` — the same tree the toolchain was built from, so
    # they can't drift.
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
    # (off→sysroot, eh→sysroot-eh, ehpic→sysroot-ehpic, …) — from the profile table.
    sysrootSubdir = profilesCfg.sysrootSubdirs.${name};

    sysroot = mkSysroot name [libc compiler-rt libcxx];

    # Basic smoke test: compile+link a C++ program against this sysroot.
    test = pkgs.callPackage ../tests/sysroot-test.nix {
      inherit name eh pic toolchainFile sysroot llvm;
    };
  in {
    inherit name eh pic exnref libc compiler-rt libcxx sysrootSubdir sysroot test;
  };

  # One variant per profile in the canonical table. `off` is threaded-but-no-EH;
  # the EH variants add C++ exceptions; `pic` builds position-independent;
  # `exnref` uses the exnref/SjLj exception model.
  variants =
    lib.mapAttrs (name: enc: mkVariant (enc // {inherit name;}))
    profilesCfg.sysrootEncodings;

  # The combined sysroot: one subdir per variant, matching the release-tarball
  # layout. wasixcc points WASIXCC_SYSROOT_PREFIX here and picks the subdir by EH/PIC.
  sysroot = pkgs.runCommand "wasix-sysroot" {} (
    ''
      mkdir -p "$out"
    ''
    + lib.concatMapStrings (v: ''
      ln -s ${v.sysroot} "$out/${v.sysrootSubdir}"
    '') (lib.attrValues variants)
  );

  # Per-variant sysroot smoke tests, keyed by variant name.
  tests = lib.mapAttrs (_: v: v.test) variants;
in
  {
    inherit variants sysroot tests;
  }
  # Default single-variant component attrs = the `off` variant.
  // {inherit (variants.off) libc compiler-rt libcxx;}
