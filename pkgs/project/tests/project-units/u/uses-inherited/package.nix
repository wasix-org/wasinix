{
  dropInputsByName,
  exposePackage,
  packageSets,
  packages,
  profileSets,
  runners,
}:
exposePackage (packages.sameProfile.inherited.overrideAttrs (_: {
  name = "uses-inherited";
  passthru = {
    usedFocusedHelper = dropInputsByName ["dependency"] [packages.sameProfile.dependency] == [];
    preferredPackageSetName = packageSets.wasix.preferred.core.name;
    topLevelPreferredPackageSetAbsent = !(packageSets ? preferred);
    runnerContextName = runners.rawWasm.unbound.name;
    profileNames = profileSets.all;
  };
}))
