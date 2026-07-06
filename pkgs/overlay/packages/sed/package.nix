{
  final,
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "sed";} (
  helpers.libTweaks {
    passthru.wasix.shipped = true;
    meta.platforms = _: final.lib.platforms.all;
  }
  prev.gnused
)
