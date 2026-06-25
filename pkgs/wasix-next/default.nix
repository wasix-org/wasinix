# WIP scaffold for the redesigned wasix toolchain, built up in parallel with the
# existing pkgs/toolchain so we can try foundations in isolation.
#
# Design (upstream-faithful): mirror wasix-libc's build32-general.sh. The fork LLVM
# provides clang/lld; the runtimes (compiler-rt, libc++/libc++abi, libunwind) are
# built by direct cmake driven by wasix-libc's committed clang-wasix*.cmake_toolchain
# files — so those files stay the single source of truth for the ABI flags, with no
# re-derivation in Nix and no fighting nixpkgs' cross defaults. libc builds from the
# wasix-libc Makefile. Per variant we stage (libc → +compiler-rt → +libcxx) and merge
# into a sysroot, exactly like build32.
#
# `mkVariant {eh, pic, exnref}` builds one of the 5 ABI variants; `variants` exposes
# all five; `sysroot` is the combined drop-in for the release-tarball layout.
#
# `nixpkgs` + `system` are unused *here*: Option B builds the runtimes as plain
# derivations (fork-clang + the toolchain files), so the toolchain/sysroot need no
# cross-nixpkgs import. They're kept for step 4 — building *child* packages via
# wasixcc wrapped in a cc-wrapper needs a wasm32-wasi cross pkgs set
# (`import nixpkgs { crossSystem = …; }` + overrideCC around wasixcc).
{
  pkgs,
  nixpkgs ? null,
  system ? "x86_64-linux",
}: let
  inherit (pkgs) lib;

  ## ── Source pins (single source of truth) ──────────────────────────────────

  # The LLVM fork has two distinct numbers: the fork *release tag* and the *base
  # LLVM version* nixpkgs needs to pick its patch set. They can't merge. The fetch
  # stays pinned by commit (immutable + the monorepo fetch is large/expensive to
  # re-resolve); the content `hash` is the real integrity guarantee either way.
  llvmVersion = "21.1.2"; # base LLVM (drives nixpkgs' patch selection)
  monorepoSrc = pkgs.fetchFromGitHub {
    owner = "wasix-org";
    repo = "llvm-project";
    rev = "21.1.203"; # fork release tag (one of 21.1.201–204 on this commit)
    hash = "sha256-IFQNaJfBTVXWYsahkCGLMbmcs6vWDEwr6xKszq7yHSM=";
  };

  wasixLibcVersion = "v2026-02-16.1";
  wasixLibcSrc = pkgs.fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasix-libc";
    rev = wasixLibcVersion; # resolve the tag; content hash pins it
    hash = "sha256-PI8Iushd3HS6+tCZ6f4agmz9TIJdL1nxpozWN90ubNY=";
  };

  ## ── The fork LLVM toolchain (clang/lld/llvm) ──────────────────────────────
  # Standard nixpkgs LLVM build with the fork source swapped in (rocm-style
  # override). Built once on the host (x86_64, multi-target → cross-compiles to
  # wasm), shared by every variant: it's the shipped toolchain *and* the compiler
  # that builds the runtimes.
  llvm = pkgs.llvmPackages_21.override (_old: {
    officialRelease = {};
    version = llvmVersion;
    src = monorepoSrc;
    inherit monorepoSrc;
    doCheck = false;
  });

  # A single LLVM install tree (bin/clang, bin/wasm-ld, bin/llvm-*, + clang's
  # resource dir) for consumers that want one location — notably wasixcc's
  # WASIXCC_LLVM_LOCATION. Replaces the prebuilt wasix-llvm tarball.
  llvmTree = pkgs.symlinkJoin {
    name = "wasix-llvm-${llvmVersion}";
    paths = [llvm.clang-unwrapped llvm.lld llvm.llvm];
  };

  ## ── Helpers ───────────────────────────────────────────────────────────────

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

  # Merge the (sysroot-shaped) component output trees into one — used for both the
  # staged build-sysroots and the final sysroot. Mirrors build32's sysroot(), which
  # rsyncs whole component outputs together: no per-subdir branching (each
  # component's own build guarantees its contents, so the loud failure already lives
  # there), and it keeps whatever each ships (e.g. compiler-rt's include/profile).
  # --no-preserve=mode so the read-only store files become writable and later
  # components can merge into the same dirs.
  mkSysroot = sname: comps:
    pkgs.runCommand "wasix-sysroot-${sname}" {} (
      ''mkdir -p "$out"
      ''
      + lib.concatMapStrings (c: ''
        cp -r --no-preserve=mode,ownership ${c}/. "$out/"
      '')
      comps
    );

  ## ── One ABI variant ───────────────────────────────────────────────────────
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

    # compiler-rt builds against a sysroot of just libc (build32 staging).
    # Its LLVM source comes from `llvm` (llvm.llvm.monorepoSrc) — same tree the
    # toolchain was built from, so they can't drift.
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
  variants =
    lib.mapAttrs (name: spec: mkVariant (spec // {inherit name;})) {
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

  # The combined sysroot: a prefix dir with one subdir per variant, matching the
  # release-tarball layout (it replaces the old download-based sysroot) — wasixcc
  # points WASIXCC_SYSROOT_PREFIX here and picks the subdir by EH/PIC.
  sysroot =
    pkgs.runCommand "wasix-sysroot" {} (
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
    inherit variants sysroot llvm llvmTree tests;
  }
  # Default top-level attrs = the `off` variant, for current (single-variant)
  # consumers of this module.
  // {inherit (variants.off) libc compiler-rt libcxx;}
