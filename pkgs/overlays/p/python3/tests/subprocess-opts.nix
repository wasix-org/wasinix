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
  subprocess-opts = harnesses.wasixShell {
    name = "python${tag}-subprocess-opts";
    shell = commands.bash;
    commands = pythonCommands ++ [commands.coreutils commands.grep];
    host.setup = ''cp ${./subprocess-opts-check.py} "$WASIX_TEST_ROOT/check.py"'';
    script = ''
      python${pyVer} -O check.py | tee out.log
      grep -q SUBPROC_OPTS_OK out.log
    '';
  };
})
