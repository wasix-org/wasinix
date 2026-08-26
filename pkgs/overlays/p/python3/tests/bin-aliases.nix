{
  commands,
  harnesses,
  helpers,
  packages,
}:
helpers.forEachPython packages.wasix.preferred ({
  pythonCommands,
  pyVer,
  tag,
}: {
  bin-aliases = harnesses.wasixShell {
    name = "python${tag}-bin-aliases";
    shell = commands.bash;
    commands = pythonCommands;
    script = ''
      for command in python python3 python${pyVer}; do
        "$command" -c \
          'import os; expected = {"python", "python3", "python${pyVer}"}; assert expected <= set(os.listdir("/bin"))'
      done
    '';
  };
})
