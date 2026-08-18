{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "gojq";} (
  helpers.libTweaks {
    passthru.wasix.shipped = true;
  }
  prev.gojq
)
