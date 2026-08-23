{exposeExtendedPackage}:
exposeExtendedPackage {
  patches = [./quoted-attribute-names.patch];
  passthru.wasinix.checks.behavior = true;
}
