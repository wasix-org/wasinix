{
  exposeNativePackageIdentity,
  packageSet,
}:
exposeNativePackageIdentity {
  package = packageSet.callPackage ./build.nix {};
  wasix.supportedProfiles = [];
}
