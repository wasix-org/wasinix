{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "qsreplace";} (
  helpers.extendPackage prev.qsreplace {
    subPackages = ["."];
    passthru.wasinix.shipped = true;
  }
)
