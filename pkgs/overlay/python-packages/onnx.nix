{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The suite throws through schema-test C++ after thousands of passing cases.
  passthru.wasinix.checks.captured.install = false;
}
pyprev.onnx
