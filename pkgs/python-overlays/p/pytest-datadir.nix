{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  # pytest-datadir declares pytest as a runtime dependency in wheel metadata.
  propagatedBuildInputs = [packages.sameProfile.pytest];
}
