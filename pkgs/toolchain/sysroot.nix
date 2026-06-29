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

  wasixLibcVersion = "v2026-02-16.1";
  wasixLibcSrc = pkgs.fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasix-libc";
    tag = wasixLibcVersion; # content hash pins it
    hash = "sha256-PI8Iushd3HS6+tCZ6f4agmz9TIJdL1nxpozWN90ubNY=";
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
  # become writable and later components can merge into the same dirs.
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
      inherit name pic llvm toolchainFile;
      version = llvmVersion;
      sysroot = mkSysroot "${name}-rtdeps" [libc];
    };

    # libcxx builds against a sysroot of libc + compiler-rt (build32 staging).
    libcxx = pkgs.callPackage ./libcxx.nix {
      inherit name eh pic llvm toolchainFile;
      version = llvmVersion;
      sysroot = mkSysroot "${name}-cxxdeps" [libc compiler-rt];
    };

    # Subdir name under the combined sysroot, matching the release tarballs
    # (off→sysroot, eh→sysroot-eh, ehpic→sysroot-ehpic, …).
    sysrootSubdir =
      "sysroot"
      + lib.optionalString eh ("-" + lib.optionalString exnref "exnref-" + "eh" + lib.optionalString pic "pic");

    sysroot = mkSysroot name [libc compiler-rt libcxx];

    # Basic smoke test: compile+link a C++ program against this sysroot.
    test = pkgs.callPackage ./test.nix {
      inherit name eh pic toolchainFile sysroot llvm;
    };
  in {
    inherit name eh pic exnref libc compiler-rt libcxx sysrootSubdir sysroot test;
  };

  # The 5 wasix ABI variants. `off` is threaded-but-no-EH; the EH variants add C++
  # exceptions; `pic` builds position-independent; `exnref` uses the exnref/SjLj
  # exception model. (PIC is only valid with EH — see build32.)
  variants = lib.mapAttrs (name: spec: mkVariant (spec // {inherit name;})) {
    off = {
      eh = false;
      pic = false;
      exnref = false;
    };
    eh = {
      eh = true;
      pic = false;
      exnref = false;
    };
    ehpic = {
      eh = true;
      pic = true;
      exnref = false;
    };
    exnrefEh = {
      eh = true;
      pic = false;
      exnref = true;
    };
    exnrefEhpic = {
      eh = true;
      pic = true;
      exnref = true;
    };
  };

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
