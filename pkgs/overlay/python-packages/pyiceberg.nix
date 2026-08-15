{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook];
  passthru.wasix.emulatedCheck.broken = "optional integration dependencies require gRPC, which does not build for WASIX";
}
pyprev.pyiceberg
