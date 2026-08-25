{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  # These invoke native development tools from inside the WASIX guest.
  disabledTests = ["test_cppcheck" "test_mypy"];
  passthru.wasixDeclaredCheckInputs = [
    packages.sameProfile.matplotlib
    packages.sameProfile.pillow
    packages.sameProfile.pytestCheckHook
    packages.sameProfile.wurlitzer
  ];
  # The suite takes about 18 minutes under emulation.
  passthru.wasinix.checks.captured.tags = ["slow-tests"];
}
