{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # These invoke native development tools from inside the WASIX guest.
  disabledTests = ["test_cppcheck" "test_mypy"];
}
pyprev.contourpy
