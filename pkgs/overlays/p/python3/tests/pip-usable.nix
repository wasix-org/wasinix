{
  commands,
  harnesses,
  helpers,
  packages,
}:
helpers.forEachPython packages.wasix.preferred ({
  pythonCommands,
  pyVer,
  tag,
}: {
  # ensurepip cannot run in a cross build, so the bundled wheel is unpacked at
  # install time; without that `import pip` is gone even though it runs fine.
  pip-usable = harnesses.wasixShell {
    name = "python${tag}-pip-usable";
    shell = commands.bash;
    commands = pythonCommands ++ [commands.coreutils commands.grep];
    host.setup = ''cp ${./pip-usable-check.py} "$WASIX_TEST_ROOT/check.py"'';
    script = ''
      python${pyVer} -m pip --version | tee out.log
      grep -q '^pip ' out.log

      pip --version | tee command.log
      grep -q '^pip ' command.log

      python${pyVer} check.py | tee install.log
      grep -q PIP_OK install.log
    '';
  };
})
