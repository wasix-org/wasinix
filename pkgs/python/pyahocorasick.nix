{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.pyahocorasick {
  passthru.wasinix.checks.captured.broken = "raw unpickle validation differs on wasm32";
}
