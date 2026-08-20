{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "gojq";} (
  helpers.extendPackage prev.gojq {
    passthru.wasinix.shipped = true;
  }
)
