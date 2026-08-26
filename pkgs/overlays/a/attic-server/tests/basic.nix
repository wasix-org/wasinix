{
  commands,
  harnesses,
  entry,
  ...
}: {
  version = harnesses.wasixShell {
    name = "attic-server-version";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands;
    script = "atticd --version";
  };
}
