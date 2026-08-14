{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The upstream self-instrumentation suite exceeds the emulator timeout.
  passthru.wasix.installCheck = false;
}
pyprev.coverage
