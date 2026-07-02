# The wasix toolchain: LLVM fork, per-variant sysroot, and the wrappers that
# drive them (wasixcc, cargo-wasix, binaryen). Everything is built from source.
{pkgs}: let
  inherit (import ./llvm.nix {inherit pkgs;}) llvm llvmTree llvmVersion;
  foundation = import ./sysroot {inherit pkgs llvm llvmVersion;};
  inherit (foundation) variants sysroot tests libc compiler-rt libcxx;

  wasixLlvm = llvmTree;
  wasixSysroot = sysroot;

  wasixRustToolchain = pkgs.callPackage ./rust/toolchain.nix {
    # The two wasix std targets use the EH and EH+PIC sysroots, as in upstream
    # build-wasix.sh.
    inherit wasixLlvm;
    wasixSysrootEh = variants.eh.sysroot;
    wasixSysrootEhpic = variants.ehpic.sysroot;
  };
  binaryen = pkgs.binaryen;
  wasixcc = pkgs.callPackage ./wasixcc.nix {
    inherit wasixLlvm binaryen wasixSysroot;
  };
  cargoWasix = pkgs.callPackage ./rust/cargo-wasix.nix {
    inherit wasixRustToolchain wasixcc wasixLlvm binaryen wasixSysroot;
  };
in {
  # Wrappers. The wasix rustPlatform is assembled in pkgs/default.nix, where the
  # pkgsCross it needs is in scope.
  inherit wasixLlvm wasixSysroot wasixRustToolchain binaryen wasixcc cargoWasix;
  # Compiler, per-variant sysroot components, and smoke tests.
  inherit llvm variants sysroot tests libc compiler-rt libcxx;
}
