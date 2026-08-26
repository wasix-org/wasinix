{
  entry,
  harnesses,
  helpers,
}: {
  packaged = harnesses.hostShell {
    name = "behavior-${entry.instance.version}";
    wasixCommands = [entry.commands.behavior];
    inherit (helpers) script;
  };
}
