{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.coverage {
  # The upstream self-instrumentation suite exceeds the emulator timeout.
  passthru.wasinix.checks.captured.install = false;
}
