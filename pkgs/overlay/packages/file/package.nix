{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/read-complete-magic-database.patch];
  # check-local runs tests/test, so capture builds the helper directly.
  wasixCheckPrebuild = ''make -C tests -j"''${NIX_BUILD_CORES:-1}" test'';
}
prev.file
