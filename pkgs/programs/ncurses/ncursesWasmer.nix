{ makeWasmerPackage, ncurses }:
makeWasmerPackage {
  package = ncurses;
  name = "ncurses";
  # TODO: should extend version to make it semver compliant
  # Actual is 6.6 atm, but don't want to manually maintain
  version = "6.6.0";
  commands = [
    {
      name = "clear";
      module = "clear";
      wasm = "clear.wasm";
      output = "clear.wasmer";
    }
    {
      name = "reset";
      module = "reset";
      wasm = "reset.wasm";
      output = "reset.wasmer";
    }
    {
      name = "tput";
      module = "tput";
      wasm = "tput.wasm";
      output = "tput.wasmer";
    }
  ];
}
