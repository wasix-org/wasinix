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
  # Both multiprocessing patches restrict _concrete_contexts on wasix, so
  # fork must fail up front with ValueError, not inside Process.start.
  mp-context = harnesses.hostShell {
    name = "python${tag}-mp-context";
    wasixCommands = pythonCommands;
    script = ''
      cp ${./mp-context-check.py} check.py
      python${pyVer} check.py | tee out.log
      grep -q MPCTX_OK out.log
    '';
  };
})
