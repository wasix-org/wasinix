{
  exposeNativePackage,
  packages,
  scope,
}:
assert scope == "native";
  exposeNativePackage packages.sameProfile.newRecipe
