{
  exposePackage,
  packages,
}:
exposePackage (packages.sameProfile.inherited.overrideAttrs (_: {name = "uses-inherited";}))
