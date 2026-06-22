{makeWasmerPackage}: {
  name,
  package,
  license ? "MIT",
}:
makeWasmerPackage {
  inherit package name license;
  entrypoint = "phpix";
  commands = [
    {
      name = "phpix";
      module = "phpix";
      wasm = "phpix.wasm";
      output = "phpix.wasm";
      atom = "phpix";
    }
    {
      name = "php";
      module = "phpix";
      wasm = "phpix.wasm";
      output = "phpix.wasm";
      atom = "phpix";
    }
  ];
}
