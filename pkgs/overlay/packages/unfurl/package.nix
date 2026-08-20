{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "unfurl";} (
  helpers.libTweaks {
    subPackages = ["."];
    passthru.wasinix.shipped = true;
  }
  prev.unfurl
)
