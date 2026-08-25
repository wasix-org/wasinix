{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.dependency.overrideAttrs (_old: {name = "complete";}))
