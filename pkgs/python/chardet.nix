{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.chardet {
  passthru.wasinix.checks.captured.timeout = 3600;
  # xdist workers are processes and disappear under WASIX.
  pytestFlags = ["-n" "0"];
}
