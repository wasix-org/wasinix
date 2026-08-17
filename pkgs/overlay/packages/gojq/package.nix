{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "gojq";} (
  helpers.libTweaks {
    subPackages = ["cmd/gojq"];
    passthru.wasix.shipped = true;
  }
  prev.gojq
)
