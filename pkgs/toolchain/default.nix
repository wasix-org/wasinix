# The wasix toolchain: the from-source compiler + sysroot (llvm.nix, sysroot.nix
# and the per-component builders) plus the wrappers that drive them (wasixcc,
# cargo-wasix, binaryen) and the shell env fragments (dev-env.nix). Everything is
# built from source, the upstream way.
{pkgs}: let
  inherit (import ./llvm.nix {inherit pkgs;}) llvm llvmTree llvmVersion;
  foundation = import ./sysroot.nix {inherit pkgs llvm llvmVersion;};
  inherit (foundation) variants sysroot tests libc compiler-rt libcxx;

  wasixLlvm = llvmTree;
  wasixSysroot = sysroot;

  wasixRustToolchain = pkgs.callPackage ./wasix-rust-toolchain.nix {
    # build-wasix.sh maps the two wasix std targets to the EH and EH+PIC libc
    # sysroots; take them (and the clang that compiles their C) from the same
    # from-source foundation.
    inherit wasixLlvm;
    wasixSysrootEh = variants.eh.sysroot;
    wasixSysrootEhpic = variants.ehpic.sysroot;
  };
  binaryen = pkgs.binaryen;
  wasixcc = pkgs.callPackage ./wasixcc.nix {
    inherit wasixLlvm binaryen wasixSysroot;
  };
  cargoWasix = pkgs.callPackage ./cargo-wasix.nix {
    inherit wasixRustToolchain wasixcc wasixLlvm binaryen wasixSysroot;
  };
in {
  # wrappers (the wasix rustPlatform is assembled in pkgs/default.nix, where the
  # plain pkgsCross it needs is in scope, and injected into the overlay).
  inherit wasixLlvm wasixSysroot wasixRustToolchain binaryen wasixcc cargoWasix;
  # from-source foundation (compiler + per-variant sysroot components + smoke tests)
  inherit llvm variants sysroot tests libc compiler-rt libcxx;
}
