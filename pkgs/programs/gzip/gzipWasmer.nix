{ makeWasmerPackage, gzip }:
makeWasmerPackage {
  package = gzip;
  # TODO: should extend version to make it semver compliant
  # Actual is 1.14 atm, but don't want to manually maintain
  version = "1.14.0";
  name = "gzip";
  commands = [
    {
      name = "gzip";
      module = "gzip";
      wasm = "gzip.wasm";
      output = "gzip.wasmer";
    }
    {
      name = "gunzip";
      module = "gunzip";
      wasm = "gzip.wasm";
      output = "gunzip.wasmer";
      mainArgs = [ "-d" "-f" ];
    }
    {
      name = "zcat";
      module = "zcat";
      wasm = "gzip.wasm";
      output = "zcat.wasmer";
      mainArgs = [ "-d" "-c" "-f" ];
    }
  ];
}
