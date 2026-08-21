{
  harnesses,
  entry,
  ...
}: {
  version = harnesses.hostShell {
    name = "attic-server-version";
    wasixCommands = builtins.attrValues entry.commands;
    script = ''
      atticd --version
      atticadm --version
    '';
  };
}
