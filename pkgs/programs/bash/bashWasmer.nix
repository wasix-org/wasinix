{
  makeWasmerPackage,
  bash,
}:
makeWasmerPackage {
  package = bash;
  name = "bash";
  inherit (bash) version;
  commands = [
    {
      name = "bash";
      module = "bash";
      wasm = "bash.wasm";
      output = "bash.wasm";
    }
  ];
}
