{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "qsreplace";} (
  helpers.libTweaks {
    subPackages = ["."];
    passthru.wasix.shipped = true;
  }
  prev.qsreplace
)
