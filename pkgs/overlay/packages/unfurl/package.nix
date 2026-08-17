{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "unfurl";} (
  helpers.libTweaks {
    subPackages = ["."];
    passthru.wasix.shipped = true;
  }
  prev.unfurl
)
