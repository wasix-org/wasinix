{
  pkgs,
  testLib,
  helpers,
  wasmerPkgs,
}:
helpers.forEachPython wasmerPkgs ({
  python,
  pyVer,
  tag,
}: {
  # Both multiprocessing patches restrict _concrete_contexts on wasix, so
  # fork must fail up front with ValueError, not inside Process.start.
  mp-context = testLib.mkWasixRun {
    name = "python${tag}-mp-context";
    wasixPkgs = [python];
    script = ''
      cp ${./mp-context-check.py} check.py
      python${pyVer} check.py | tee out.log
      grep -q MPCTX_OK out.log
    '';
  };
})
