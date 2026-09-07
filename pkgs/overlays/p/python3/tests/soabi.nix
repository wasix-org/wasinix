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
  # Every extension in the wheel index is named for the interpreter's SOABI, so
  # a triplet change stops the whole index from importing.
  soabi = harnesses.wasixShell {
    name = "python${tag}-soabi";
    shell = commands.bash;
    commands = pythonCommands ++ [commands.coreutils commands.grep];
    host.setup = ''cp ${./soabi-check.py} "$WASIX_TEST_ROOT/check.py"'';
    script = ''
      python${pyVer} check.py | tee out.log
      grep -q SOABI_OK out.log
    '';
  };
})
