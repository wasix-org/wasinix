{ pkgs }:
let
  wasixLlvm = pkgs.callPackage ./wasix-llvm.nix { };
  wasixRustToolchain = pkgs.callPackage ./wasix-rust-toolchain.nix { };
  binaryen = pkgs.callPackage ./binaryen.nix { };
  wasixSysroot = pkgs.callPackage ./wasix-sysroot.nix { };
  wasixcc = pkgs.callPackage ./wasixcc.nix {
    inherit wasixLlvm binaryen wasixSysroot;
  };
  cargoWasix = pkgs.callPackage ./cargo-wasix.nix {
    inherit wasixRustToolchain wasixcc wasixLlvm binaryen wasixSysroot;
  };
in
{
  inherit wasixLlvm wasixRustToolchain binaryen wasixSysroot wasixcc cargoWasix;
}
