{ makeWasmerPackage, crabsay }:
makeWasmerPackage {
  package = crabsay;
  name = "crabsay";
  commands = [
    {
      name = "crabsay";
      module = "crabsay";
      wasm = "crabsay.wasm";
      output = "crabsay.wasmer";
    }
  ];
}
