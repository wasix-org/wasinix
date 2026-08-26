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
  # Both multiprocessing patches restrict _concrete_contexts on wasix, so
  # fork must fail up front with ValueError, not inside Process.start.
  mp-context = harnesses.wasixShell {
    name = "python${tag}-mp-context";
    shell = commands.bash;
    commands = pythonCommands ++ [commands.coreutils commands.grep];
    host.setup = ''cp ${./mp-context-check.py} "$WASIX_TEST_ROOT/check.py"'';
    script = ''
      python${pyVer} check.py | tee out.log
      grep -q MPCTX_OK out.log
    '';
  };
})
