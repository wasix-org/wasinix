{
  commands,
  harnesses,
  entry,
  ...
}: {
  version = harnesses.wasixShell {
    name = "attic-client-version";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands;
    script = "attic --version";
  };
}
