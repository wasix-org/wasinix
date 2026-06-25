{pkgs}: let
  # From-source toolchain + sysroot (built the upstream way; see pkgs/wasix-next),
  # replacing the prebuilt wasix-llvm tarball and the downloaded sysroot.
  wasixNext = import ../wasix-next {inherit pkgs;};
  wasixLlvm = wasixNext.llvmTree;
  wasixSysroot = wasixNext.sysroot;

  wasixRustToolchain = pkgs.callPackage ./wasix-rust-toolchain.nix {};
  binaryen = pkgs.callPackage ./binaryen.nix {};
  wasixcc = pkgs.callPackage ./wasixcc.nix {
    inherit wasixLlvm binaryen wasixSysroot;
  };
  cargoWasix = pkgs.callPackage ./cargo-wasix.nix {
    inherit wasixRustToolchain wasixcc wasixLlvm binaryen wasixSysroot;
  };
in {
  inherit wasixLlvm wasixRustToolchain binaryen wasixSysroot wasixcc cargoWasix;
}
