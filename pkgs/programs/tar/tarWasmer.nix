{
  makeWasmerPackage,
  tar,
}:
makeWasmerPackage {
  package = tar;
  name = "tar";
  version = "1.35.0";
  description = "GNU tar archiver";
  commands = [
    {
      name = "tar";
      module = "tar";
      wasm = "tar.wasm";
      output = "tar.wasm";
    }
  ];
}
