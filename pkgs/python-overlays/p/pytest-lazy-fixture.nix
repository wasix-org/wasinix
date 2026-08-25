{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  # pytest-lazy-fixture declares pytest as a runtime dependency in wheel metadata.
  propagatedBuildInputs = [packages.sameProfile.pytest];
}
