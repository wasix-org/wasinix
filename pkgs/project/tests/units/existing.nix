{
  package,
  packages,
  extendPackage,
}:
extendPackage package {
  buildInputs = [packages.sameProfile.dependency];
  passthru.wasinix.test = true;
}
