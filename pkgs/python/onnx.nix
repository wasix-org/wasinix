{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.onnx {
  # The suite throws through schema-test C++ after thousands of passing cases.
  passthru.wasinix.checks.captured.install = false;
}
