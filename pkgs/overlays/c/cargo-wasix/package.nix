{
  exposeNativePackage,
  pkgs,
}:
exposeNativePackage (pkgs.callPackage ./build.nix {})
