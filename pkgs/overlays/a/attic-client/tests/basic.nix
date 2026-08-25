{
  harnesses,
  entry,
  ...
}: {
  version = harnesses.hostShell {
    name = "attic-client-version";
    wasixCommands = builtins.attrValues entry.commands;
    script = "attic --version";
  };
}
