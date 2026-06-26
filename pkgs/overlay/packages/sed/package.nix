{
  final,
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "sed";} (
  helpers.libTweaks {
    overrideAttrs = old: {
      meta = old.meta // {platforms = final.lib.platforms.all;};
    };
  }
  prev.gnused
)
