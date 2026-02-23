{ makePlainWasmerPackage }:
makePlainWasmerPackage {
  name = "wasmer/cli-platform";
  packageName = "cli";
  version = "0.1.0";
  description = "CLI platform - a wrapper package with many common tools, useful for interactive environments.";
  entrypoint = "bash";
  dependencies = {
    "wasmer/bash" = "*";
    "curl/curl" = "*";
    "wasmer/nano" = "*";
  };
  commands = [
    {
      name = "bash";
      module = "wasmer/bash:bash";
      runner = "https://webc.org/runner/wasi";
    }
  ];
}
