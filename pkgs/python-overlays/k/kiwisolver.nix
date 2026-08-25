{
  exposeExtendedPackage,
  packages,
  dropInputsByName,
}:
exposeExtendedPackage {
  nativeBuildInputs = [packages.sameProfile.cppy];
  buildInputs = dropInputsByName ["cppy"];
  propagatedBuildInputs = dropInputsByName ["cppy"];
  disabledTestPaths = ["py/tests/test_expression.py"];
  # Solver exceptions currently trap while unwinding through the extension.
  passthru.wasinix.checks.captured.install = false;
}
