{exposeExtendedPackage}:
exposeExtendedPackage {
  pytestFlags = ["--deselect=tests/test_console.py::test_brokenpipeerror"];
}
