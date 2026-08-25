{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  buildInputs = ["wasix-input"];
  passthru.wasix.supportedProfiles = ["default"];
}
