{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.python-rapidjson {
  passthru.wasinix.checks.captured.broken = "circular-input tests exhaust the Wasm call stack";
}
