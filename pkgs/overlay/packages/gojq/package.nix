{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "gojq";} (
  helpers.libTweaks {
    passthru.wasinix.shipped = true;
  }
  prev.gojq
)
