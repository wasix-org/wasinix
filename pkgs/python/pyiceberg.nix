{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  passthru.wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook];
  passthru.wasinix.checks.captured.broken = "optional integration dependencies require gRPC, which does not build for WASIX";
}
