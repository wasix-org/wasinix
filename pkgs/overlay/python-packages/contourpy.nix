{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.extendPackage pyprev.contourpy {
  # These invoke native development tools from inside the WASIX guest.
  disabledTests = ["test_cppcheck" "test_mypy"];
  passthru.wasixDeclaredCheckInputs = [
    pyfinal.matplotlib
    pyfinal.pillow
    pyfinal.pytestCheckHook
    pyfinal.wurlitzer
  ];
  # The suite takes about 18 minutes under emulation.
  passthru.wasinix.checks.captured.tags = ["slow-tests"];
}
