{exposeNativeExtendedPackage}:
exposeNativeExtendedPackage {
  patches = [
    ./quoted-attribute-names.patch
    ./select-file.patch
  ];
  passthru.wasix.supportedProfiles = [];
  passthru.wasinix.checks.behavior = true;
}
