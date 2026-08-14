{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The functional/docs suite exceeds the emulator's 1200-second cap.
  passthru.wasix.installCheck = false;
}
pyprev.boto3
