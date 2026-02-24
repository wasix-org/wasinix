{ pkgs }:
let
  wasixLlvm = pkgs.callPackage ./wasix-llvm.nix { };
  binaryen = pkgs.callPackage ./binaryen.nix { };
  wasixSysroot = pkgs.callPackage ./wasix-sysroot.nix { };
  wasixcc = pkgs.callPackage ./wasixcc.nix {
    inherit wasixLlvm binaryen wasixSysroot;
  };
in
{
  inherit wasixLlvm binaryen wasixSysroot wasixcc;
}
