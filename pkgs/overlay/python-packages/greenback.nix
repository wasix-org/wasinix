{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.extendPackage pyprev.greenback {
  # The upstream suite imports Trio unconditionally, which dispatches WASIX
  # to its unavailable kqueue backend. Keep the wheel import check.
  passthru.wasinix.checks.captured.install = false;
}
