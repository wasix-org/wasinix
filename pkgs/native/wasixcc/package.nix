{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (packages.sameProfile.callPackage ./recipe.nix {inherit (pkgs) nix-update-script;})
