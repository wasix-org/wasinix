{
  makeWasmerPackage,
  shShim,
}:
makeWasmerPackage {
  package = shShim;
  name = "sh";
  inherit (shShim) version;
  description = "POSIX shell stub for WASIX environments";
  commands = [
    {
      name = "sh";
      module = "sh";
      wasm = "sh.wasm";
      output = "sh.wasm";
    }
  ];
}
