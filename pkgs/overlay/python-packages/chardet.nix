{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.emulatedCheck.timeout = 3600;
  # xdist workers are processes and disappear under WASIX.
  pytestFlags = ["-n" "0"];
}
pyprev.chardet
