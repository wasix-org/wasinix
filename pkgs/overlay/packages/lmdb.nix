{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The default build already produces the programs that `make test` runs.
  wasixCheckPrebuild = ":";
}
prev.lmdb
