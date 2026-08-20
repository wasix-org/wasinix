{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "circular-input tests exhaust the Wasm call stack";
}
pyprev.python-rapidjson
