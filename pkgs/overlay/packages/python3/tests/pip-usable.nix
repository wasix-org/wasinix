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
  # ensurepip cannot run in a cross build, so the bundled wheel is unpacked at
  # install time; without that `import pip` is gone even though it runs fine.
  pip-usable = testLib.mkWasixRun {
    name = "python${tag}-pip-usable";
    wasixPkgs = [python];
    script = ''
      python${pyVer} -m pip --version | tee out.log
      grep -q '^pip ' out.log

      cp ${./pip-usable-check.py} check.py
      python${pyVer} check.py | tee install.log
      grep -q PIP_OK install.log
    '';
  };
})
