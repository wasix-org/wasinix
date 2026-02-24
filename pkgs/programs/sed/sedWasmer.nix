{ makeWasmerPackage, sed }:
makeWasmerPackage {
  package = sed;
  name = "sed";
  # TODO: should extend version to make it semver compliant
  # Actual is 4.9 atm, but don't want to manually maintain
  version = "4.9.0";
  commands = [
    {
      name = "sed";
      module = "sed";
      wasm = "sed.wasm";
      output = "sed.wasmer";
    }
  ];
}
