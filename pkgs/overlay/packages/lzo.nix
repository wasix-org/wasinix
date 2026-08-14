{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  checkTarget = "check-local";
  # automake's check-local runs its binaries regardless of TESTS=, and the test
  # build is wasmer-free, so the generic prebuild would die on "cannot execute
  # binary file". Build the program only.
  wasixCheckPrebuild = ''make -j"''${NIX_BUILD_CORES:-1}" lzotest/lzotest'';
}
prev.lzo
