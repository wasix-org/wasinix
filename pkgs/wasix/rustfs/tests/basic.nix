# Runtime smoke tests for the rustfs webc under wasmer. `--version`/`--help` are
# handled by clap in Opt::parse_command and exit 0 before the server binds, so
# they exercise the whole startup path that matters for "does it run": the wasm
# module loads, std/env init and the tokio runtime come up, and argv parsing
# works — without needing storage volumes or a bound port.
{
  wasmerPkgs,
  testLib,
  ...
}: let
  wasix = [wasmerPkgs.rustfs];
in {
  version = testLib.mkWasixRun {
    name = "rustfs-version";
    wasixPkgs = wasix;
    script = "rustfs --version";
  };

  help = testLib.mkWasixRun {
    name = "rustfs-help";
    wasixPkgs = wasix;
    script = "rustfs --help";
  };
}
