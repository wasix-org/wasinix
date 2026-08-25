{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  propagatedBuildInputs = [packages.sameProfile.starlette];
}
