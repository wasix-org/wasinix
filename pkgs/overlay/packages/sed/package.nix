{
  final,
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "sed";} (
  helpers.libTweaks {
    meta.platforms = _: final.lib.platforms.all;
  }
  prev.gnused
)
