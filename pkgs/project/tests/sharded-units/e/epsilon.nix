{
  exposeWasixPackage,
  packageSet,
}:
exposeWasixPackage (packageSet.alpha.overrideAttrs (_old: {name = "epsilon-wasix";}))
