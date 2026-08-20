{
  exposePackage,
  packages,
}:
exposePackage (packages.sameProfile.inheritedPython.overrideAttrs (_: {name = "uses-python";}))
