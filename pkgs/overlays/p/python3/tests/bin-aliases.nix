{
  pkgs,
  harnesses,
  helpers,
  packages,
}:
helpers.forEachPython packages.wasix.preferred ({
  python,
  pythonCommands,
  pyVer,
  tag,
}: {
  bin-aliases = harnesses.hostShell {
    name = "python${tag}-bin-aliases";
    wasixCommands = pythonCommands;
    script = ''
      for command in python python3 python${pyVer}; do
        "${pkgs.lib.getExe' python "$command"}" -c \
          'import os; expected = {"python", "python3", "python${pyVer}"}; assert expected <= set(os.listdir("/bin"))'
      done
    '';
  };
})
