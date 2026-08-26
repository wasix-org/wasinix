{
  extendPackage,
  exposeNativePackage,
  packageSet,
}:
exposeNativePackage (extendPackage (packageSet.callPackage ./build.nix {}) {
  passthru.wasix.supportedProfiles = [];
})
