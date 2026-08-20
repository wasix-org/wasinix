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
  ctypes-findlib = testLib.mkWasixRun {
    name = "python${tag}-ctypes-findlib";
    wasixPkgs = [python];
    script = ''
      cp ${./ctypes-findlib-check.py} check.py
      python${pyVer} check.py | tee out.log
      grep -q FINDLIB_OK out.log
    '';
  };
})
