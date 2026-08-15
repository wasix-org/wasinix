{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The default build already produces the programs that `make test` runs.
  wasixCheckPrebuild = ":";
  passthru.wasix.emulatedCheck.broken = "MDB_FIXEDMAP is unsupported by WASIX mmap";
}
prev.lmdb
