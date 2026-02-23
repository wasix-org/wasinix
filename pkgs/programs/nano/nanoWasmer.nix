{ makeWasmerPackage, nano }:
makeWasmerPackage {
  package = nano;
  name = "nano";
  commands = [
    {
      name = "nano";
      module = "nano";
      wasm = "nano.wasm";
      output = "nano.wasmer";
    }
  ];
}
