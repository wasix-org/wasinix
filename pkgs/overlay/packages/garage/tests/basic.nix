# Runtime smoke tests for the garage webc under wasmer. clap answers
# --version/--help before the config file is read or sodiumoxide initialises, so
# they cover module load, std/env init and argv parsing without a cluster.
{
  wasmerPkgs,
  testLib,
  ...
}: let
  wasix = [wasmerPkgs.garage];
in {
  version = testLib.mkWasixRun {
    name = "garage-version";
    wasixPkgs = wasix;
    script = "garage --version";
  };

  help = testLib.mkWasixRun {
    name = "garage-help";
    wasixPkgs = wasix;
    script = "garage --help";
  };
}
