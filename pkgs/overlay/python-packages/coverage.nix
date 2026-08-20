{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The upstream self-instrumentation suite exceeds the emulator timeout.
  passthru.wasinix.checks.captured.install = false;
}
pyprev.coverage
