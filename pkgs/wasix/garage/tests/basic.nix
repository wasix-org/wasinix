# Runtime smoke tests for the garage webc under wasmer. clap answers
# --version/--help before the config file is read or sodiumoxide initialises, so
# they cover module load, std/env init and argv parsing without a cluster.
{
  entry,
  harnesses,
  ...
}: let
  wasix = builtins.attrValues entry.commands;
in {
  version = harnesses.hostShell {
    name = "garage-version";
    wasixCommands = wasix;
    script = "garage --version";
  };

  help = harnesses.hostShell {
    name = "garage-help";
    wasixCommands = wasix;
    script = "garage --help";
  };
}
