{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.rich {
  pytestFlags = ["--deselect=tests/test_console.py::test_brokenpipeerror"];
}
