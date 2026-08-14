{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  pytestFlags = ["--deselect=tests/test_console.py::test_brokenpipeerror"];
}
pyprev.rich
