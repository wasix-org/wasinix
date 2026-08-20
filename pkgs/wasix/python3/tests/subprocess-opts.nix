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
  subprocess-opts = testLib.mkWasixRun {
    name = "python${tag}-subprocess-opts";
    wasixPkgs = [python];
    script = ''
      cp ${./subprocess-opts-check.py} check.py
      python${pyVer} -O check.py | tee out.log
      grep -q SUBPROC_OPTS_OK out.log
    '';
  };
})
