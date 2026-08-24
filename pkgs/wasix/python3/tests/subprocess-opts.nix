{
  harnesses,
  helpers,
  packages,
}:
helpers.forEachPython packages.preferred ({
  pythonCommands,
  pyVer,
  tag,
}: {
  subprocess-opts = harnesses.hostShell {
    name = "python${tag}-subprocess-opts";
    wasixCommands = pythonCommands;
    script = ''
      cp ${./subprocess-opts-check.py} check.py
      python${pyVer} -O check.py | tee out.log
      grep -q SUBPROC_OPTS_OK out.log
    '';
  };
})
