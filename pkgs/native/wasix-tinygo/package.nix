{
  exposePackage,
  packages,
}:
exposePackage (packages.sameProfile.callPackage ./recipe.nix {})
