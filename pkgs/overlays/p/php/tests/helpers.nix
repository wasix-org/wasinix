{pkgs}: let
  versions = import ../versions.nix;
in {
  mkPhpShims = suffix: {
    crossPkgs,
    makeWasmerPackage,
  }:
    pkgs.lib.mapAttrs (attr: _:
      (makeWasmerPackage {package = crossPkgs."${attr}${suffix}";}).shim)
    versions;
}
