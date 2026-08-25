{
  dropInputsByName,
  exposePackage,
  packages,
  profileSets,
  runners,
}:
exposePackage (packages.sameProfile.inherited.overrideAttrs (_: {
  name = "uses-inherited";
  passthru = {
    usedFocusedHelper = dropInputsByName ["dependency"] [packages.sameProfile.dependency] == [];
    runnerContextName = runners.rawWasm.unbound.name;
    profileNames = profileSets.all;
  };
}))
