{
  makeWasmerPackage,
  curl,
}:
makeWasmerPackage {
  package = curl;
  name = "curl";
  inherit (curl) version;
  description = "command line tool and library for transferring data with URLs";
  commands = [
    {
      name = "curl";
      module = "curl";
      wasm = "curl.wasm";
      output = "curl.wasm";
    }
  ];
}
