{
  exposeNativePackageIdentity,
  packageSet,
}:
exposeNativePackageIdentity {
  package = packageSet."wasix-rust";
  wasix.supportedProfiles = ["eh"];
}
