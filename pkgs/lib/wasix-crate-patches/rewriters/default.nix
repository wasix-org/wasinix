# The reusable source rewriters, one script derivation per file. A crate's
# edits.nix runs one by interpolating its store path in a patchPhase
# (`${rewriters.wasmerAsNative}`), so editing a rewriter rebuilds only the crates
# that use it and adding one rebuilds nothing.
{pkgs}: let
  inherit (pkgs) lib;
  isRewriter = name: type:
    type == "regular" && lib.hasSuffix ".nix" name && name != "default.nix";
in
  lib.mapAttrs'
  (name: _:
    lib.nameValuePair (lib.removeSuffix ".nix" name)
    (pkgs.callPackage (./. + "/${name}") {}))
  (lib.filterAttrs isRewriter (builtins.readDir ./.))
