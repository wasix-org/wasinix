{
  pkgs,
  testLib,
  helpers,
  preferredProfilePackages,
}:
helpers.forEachPython preferredProfilePackages ({
  python,
  pyVer,
  tag,
}: {
  bin-aliases = testLib.mkWasixRun {
    name = "python${tag}-bin-aliases";
    wasixPkgs = [python];
    script = ''
      for command in python python3 python${pyVer}; do
        "${pkgs.lib.getExe' python "$command"}" -c \
          'import os; expected = {"python", "python3", "python${pyVer}"}; assert expected <= set(os.listdir("/bin"))'
      done
    '';
  };
})
