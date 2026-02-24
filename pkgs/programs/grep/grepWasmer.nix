{ makeWasmerPackage, grep }:
makeWasmerPackage {
  package = grep;
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
