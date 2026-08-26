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
  # ensurepip cannot run in a cross build, so the bundled wheel is unpacked at
  # install time; without that `import pip` is gone even though it runs fine.
  pip-usable = harnesses.hostShell {
    name = "python${tag}-pip-usable";
    wasixCommands = pythonCommands;
    script = ''
      python${pyVer} -m pip --version | tee out.log
      grep -q '^pip ' out.log

      pip --version | tee command.log
      grep -q '^pip ' command.log

      cp ${./pip-usable-check.py} check.py
      python${pyVer} check.py | tee install.log
      grep -q PIP_OK install.log
    '';
  };
})
