{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "qsreplace";} (
  helpers.libTweaks {
    subPackages = ["."];
    passthru.wasinix.shipped = true;
  }
  prev.qsreplace
)
