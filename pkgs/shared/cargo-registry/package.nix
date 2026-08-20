{
  exposePackage,
  nix-update-script,
  packages,
}:
exposePackage (packages.sameProfile.callPackage ./recipe.nix {inherit nix-update-script;})
