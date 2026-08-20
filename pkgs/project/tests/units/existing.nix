{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  buildInputs = [packages.sameProfile.dependency];
  passthru.wasinix.test = true;
}
