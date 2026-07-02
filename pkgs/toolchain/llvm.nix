# The wasix-org LLVM fork (clang/lld/llvm), built via nixpkgs' llvmPackages with
# the fork source swapped in. Built once on the host x86_64; it is both the
# shipped toolchain and the compiler that builds the sysroot runtimes.
{pkgs}: let
  # Two distinct version numbers: the fork's release tag (pins the fetch) and the
  # base LLVM version (selects nixpkgs' patch set).
  llvmVersion = "21.1.2"; # base LLVM (drives nixpkgs' patch selection)
  monorepoSrc = pkgs.fetchFromGitHub {
    owner = "wasix-org";
    repo = "llvm-project";
    tag = "21.1.204"; # fork release tag (one of 21.1.201-204 on this commit)
    hash = "sha256-IFQNaJfBTVXWYsahkCGLMbmcs6vWDEwr6xKszq7yHSM=";
  };

  # The stock compiler-rt/libcxx are invalid for wasix and the replacements are
  # per-ABI-variant, so override them with a throw pointing at variants.<v>. Safe:
  # the pieces we use (clang-unwrapped/lld/llvm/monorepoSrc) don't depend on them.
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

  # Single LLVM install tree (clang, wasm-ld, llvm-*, clang's resource dir) for
  # consumers that need one location, notably wasixcc's WASIXCC_LLVM_LOCATION.
  llvmTree = pkgs.symlinkJoin {
    name = "wasix-llvm-${llvmVersion}";
    paths = [llvm.clang-unwrapped llvm.lld llvm.llvm];
  };
in {
  inherit llvmVersion monorepoSrc llvm llvmTree;
}
