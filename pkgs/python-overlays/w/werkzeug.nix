{exposeExtendedPackage}:
exposeExtendedPackage {
  pytestFlags = [
    "--deselect=tests/test_debug.py::TestDebugHelpers::test_exc_divider_found_on_chained_exception"
    "--deselect=tests/test_debug.py::test_debugged_application_pin_security_false"
    "--deselect=tests/test_debug.py::test_get_machine_id"
  ];
}
