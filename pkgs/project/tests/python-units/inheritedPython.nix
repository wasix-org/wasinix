{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  passthru.wasinix.historyDependency = packages.wasix.default.core.versions."0.9".version;
  passthru.wasinix.pythonOverride = true;
}
