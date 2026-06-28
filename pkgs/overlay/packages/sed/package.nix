{
  final,
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "sed";} (
  helpers.libTweaks {
    # Replace platforms (not append): deep-merge would append a list, so use a
    # function to override the old value outright.
    meta.platforms = _: final.lib.platforms.all;
  }
  prev.gnused
)
