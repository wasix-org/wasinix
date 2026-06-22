{
  makeWasmerPackage,
  less,
}:
makeWasmerPackage {
  package = less;
  version = "685.0.1";
  name = "less";
  commands = [
    {
      name = "less";
      module = "less";
      wasm = "less.wasm";
      output = "less.wasm";
    }
  ];
}
