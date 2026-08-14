# The wasix-org LLVM fork, built once on the host from the shared product recipe.
{pkgs}: let
  inherit (pkgs.wasix-llvm) passthru;
in {
  inherit (passthru) version llvmVersion monorepoSrc llvm;
  llvmTree = pkgs.wasix-llvm;
}
