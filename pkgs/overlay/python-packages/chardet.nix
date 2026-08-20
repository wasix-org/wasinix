{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.timeout = 3600;
  # xdist workers are processes and disappear under WASIX.
  pytestFlags = ["-n" "0"];
}
pyprev.chardet
