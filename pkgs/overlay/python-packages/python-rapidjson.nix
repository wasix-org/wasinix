{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.emulatedCheck.broken = "circular-input tests exhaust the Wasm call stack";
}
pyprev.python-rapidjson
