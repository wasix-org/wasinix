# The wasix-org LLVM fork (clang/lld/llvm), built the standard nixpkgs way with the
# fork source swapped in (rocm-style override). Built once on the host (x86_64,
# multi-target → cross-compiles to wasm); it is both the shipped toolchain and the
# compiler that builds the sysroot runtimes.
{pkgs}: let
  # The fork has two distinct numbers: the fork *release tag* and the *base LLVM
  # version* nixpkgs needs to pick its patch set — they can't merge. The fetch
  # stays pinned by commit (immutable + the monorepo fetch is large to re-resolve);
  # the content `hash` is the real integrity guarantee either way.
  llvmVersion = "21.1.2"; # base LLVM (drives nixpkgs' patch selection)
  monorepoSrc = pkgs.fetchFromGitHub {
    owner = "wasix-org";
    repo = "llvm-project";
    rev = "21.1.203"; # fork release tag (one of 21.1.201–204 on this commit)
    hash = "sha256-IFQNaJfBTVXWYsahkCGLMbmcs6vWDEwr6xKszq7yHSM=";
  };

  # The stock llvmPackages.compiler-rt/libcxx are invalid for wasix, and there's no
  # single valid replacement — they're per-ABI-variant. Override the scope members
  # with a throw pointing at the real per-variant source. Safe because the pieces we
  # consume (clang-unwrapped/lld/llvm/monorepoSrc) don't depend on compiler-rt or
  # libcxx, so the throw only ever fires on a (wrong) direct access.
  perVariant = comp:
    throw "toolchain.llvm.${comp}: wasix ${comp} is per-ABI-variant — there is no single one. Use toolchain.variants.<variant>.${comp} (e.g. variants.exnrefEh.${comp}).";
  llvm =
    (pkgs.llvmPackages_21.override (_old: {
      officialRelease = {};
      version = llvmVersion;
      src = monorepoSrc;
      inherit monorepoSrc;
      doCheck = false;
    }))
    .overrideScope (_final: _prev: {
      compiler-rt = perVariant "compiler-rt";
      libcxx = perVariant "libcxx";
    });

  # A single LLVM install tree (bin/clang, bin/wasm-ld, bin/llvm-*, + clang's
  # resource dir) for consumers that want one location — notably wasixcc's
  # WASIXCC_LLVM_LOCATION.
  llvmTree = pkgs.symlinkJoin {
    name = "wasix-llvm-${llvmVersion}";
    paths = [llvm.clang-unwrapped llvm.lld llvm.llvm];
  };
in {
  inherit llvmVersion monorepoSrc llvm llvmTree;
}
