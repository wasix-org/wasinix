{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The functional/docs suite exceeds the emulator's 1200-second cap.
  passthru.wasinix.checks.captured.install = false;
}
pyprev.boto3
