{
  dropInputsByName,
  exposePackage,
  packages,
}:
exposePackage (packages.sameProfile.inherited.overrideAttrs (_: {
  name = "uses-inherited";
  passthru.usedFocusedHelper = dropInputsByName ["dependency"] [packages.sameProfile.dependency] == [];
}))
