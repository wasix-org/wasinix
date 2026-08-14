{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  # The upstream suite imports Trio unconditionally, which dispatches WASIX
  # to its unavailable kqueue backend. Keep the wheel import check.
  passthru.wasix.installCheck = false;
}
pyprev.greenback
