{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.libsodium {
  # no emulated check: the test programs fail to link on wasix (-fPIC
  # relocation mismatch). doCheck above composes after the check-output
  # wrapper reads old.doCheck, so it's invisible to the wrapper and the
  # build-time snapshot still tries to build the tests; wasixCheckPrebuild
  # skips that attempt directly.
  doCheck = false;
  wasixCheckPrebuild = ":";
}
