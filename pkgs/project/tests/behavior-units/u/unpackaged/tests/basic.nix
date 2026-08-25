{
  entry,
  harnesses,
}: {
  direct = harnesses.hostShell {
    name = "unpackaged-${entry.instance.version}";
    wasixCommands = builtins.attrValues entry.commands;
    script = "true";
  };
}
