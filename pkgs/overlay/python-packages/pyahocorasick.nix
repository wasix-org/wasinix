{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "raw unpickle validation differs on wasm32";
}
pyprev.pyahocorasick
