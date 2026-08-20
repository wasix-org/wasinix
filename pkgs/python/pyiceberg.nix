{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.extendPackage pyprev.pyiceberg {
  passthru.wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook];
  passthru.wasinix.checks.captured.broken = "optional integration dependencies require gRPC, which does not build for WASIX";
}
