{
  exposeExtendedPackage,
  scope,
}:
exposeExtendedPackage {
  scopeMarker = scope;
  passthru.wasix.supportedProfiles = [];
}
