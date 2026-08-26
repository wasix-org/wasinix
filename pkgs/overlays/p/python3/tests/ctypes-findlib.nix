{
  harnesses,
  helpers,
  packages,
}:
helpers.forEachPython packages.wasix.preferred ({
  pythonCommands,
  pyVer,
  tag,
}: {
  ctypes-findlib = harnesses.hostShell {
    name = "python${tag}-ctypes-findlib";
    wasixCommands = pythonCommands;
    script = ''
      cp ${./ctypes-findlib-check.py} check.py
      python${pyVer} check.py | tee out.log
      grep -q FINDLIB_OK out.log
    '';
  };
})
