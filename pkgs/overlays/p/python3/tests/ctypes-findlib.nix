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
  ctypes-findlib = harnesses.wasixShell {
    name = "python${tag}-ctypes-findlib";
    shell = commands.bash;
    commands = pythonCommands ++ [commands.coreutils commands.grep];
    host.setup = ''cp ${./ctypes-findlib-check.py} "$WASIX_TEST_ROOT/check.py"'';
    script = ''
      python${pyVer} check.py | tee out.log
      grep -q FINDLIB_OK out.log
    '';
  };
})
