# No suite: the tests spawn sys.executable, and an in-guest exec of the
# shebanged interpreter re-enters the wasix-run stub (WASIX-TODO.md).
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.anthropic {
  passthru.wasinix.checks.captured.install = false;
}
