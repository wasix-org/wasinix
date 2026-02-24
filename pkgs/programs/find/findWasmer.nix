{ makeWasmerPackage, find }:
makeWasmerPackage {
  package = find;
  name = "find";
  # TODO: should extend version to make it semver compliant
  # Actual is 4.10 atm, but don't want to manually maintain
  version = "4.10.0";
  commands = [
    {
      name = "find";
      module = "find";
      wasm = "find.wasm";
      output = "find.wasmer";
    }
  ];
}
