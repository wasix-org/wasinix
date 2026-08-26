# Runtime behavior checks for the Garage WebC under Wasmer. clap answers
# --version/--help before the config file is read or sodiumoxide initialises, so
# they cover module load, std/env init and argv parsing without a cluster.
{
  commands,
  entry,
  harnesses,
  ...
}: let
  wasix = builtins.attrValues entry.commands;
in {
  version = harnesses.wasixShell {
    name = "garage-version";
    shell = commands.bash;
    commands = wasix;
    script = "garage --version";
  };

  help = harnesses.wasixShell {
    name = "garage-help";
    shell = commands.bash;
    commands = wasix;
    script = "garage --help";
  };
}
