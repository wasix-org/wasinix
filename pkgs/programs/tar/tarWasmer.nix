{ makeWasmerPackage, tar }:
makeWasmerPackage {
  package = tar;
  name = "tar";
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
