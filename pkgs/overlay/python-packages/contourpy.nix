{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  # These invoke native development tools from inside the WASIX guest.
  disabledTests = ["test_cppcheck" "test_mypy"];
  passthru.wasixDeclaredCheckInputs = [
    pyfinal.matplotlib
    pyfinal.pillow
    pyfinal.pytestCheckHook
    pyfinal.wurlitzer
  ];
}
pyprev.contourpy
