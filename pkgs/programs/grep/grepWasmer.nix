{ makeWasmerPackage, grep }:
makeWasmerPackage {
  package = grep;
  # TODO: should extend version to make it semver compliant
  # Actual is 3.12 atm, but don't want to manually maintain
  version = "3.12.0";
  name = "grep";
  commands = [
    {
      name = "grep";
      module = "grep";
      wasm = "grep.wasm";
      output = "grep.wasmer";
    }
  ];
}
