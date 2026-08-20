{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "unfurl";} (
  helpers.extendPackage prev.unfurl {
    subPackages = ["."];
    passthru.wasinix.shipped = true;
  }
)
