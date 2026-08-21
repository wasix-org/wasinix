# nixpkgs does not run pyparsing's suite; opt in to the unit tests. The rest of
# tests/ is railroad-diagram and example scripts that need optional extras.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.checks.captured.install = true;
  enabledTestPaths = ["tests/test_unit.py" "tests/test_simple_unit.py" "tests/test_util.py"];
}
