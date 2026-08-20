{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.lmdb {
  # The default build already produces the programs that `make test` runs.
  wasixCheckPrebuild = ":";
  passthru.wasinix.checks.captured.broken = "MDB_FIXEDMAP is unsupported by WASIX mmap";
}
