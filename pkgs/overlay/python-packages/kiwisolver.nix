{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  nativeBuildInputs = [pyprev.cppy];
  buildInputs = helpers.dropInputsByName ["cppy"];
  propagatedBuildInputs = helpers.dropInputsByName ["cppy"];
  disabledTestPaths = ["py/tests/test_expression.py"];
  # Solver exceptions currently trap while unwinding through the extension.
  passthru.wasinix.checks.captured.install = false;
}
pyprev.kiwisolver
