{exposeExtendedPackage}:
exposeExtendedPackage {
  patches = [
    ./quoted-attribute-names.patch
    ./select-file.patch
  ];
  passthru.wasinix.checks.behavior = true;
}
