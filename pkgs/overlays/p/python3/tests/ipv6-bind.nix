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
  # CPython's configure disables ipv6 for WASI, where wasi-libc has no
  # AF_INET6; WASIX has it, and getaddrinfo hands out AF_INET6 either way.
  ipv6-bind = harnesses.wasixShell {
    name = "python${tag}-ipv6-bind";
    shell = commands.bash;
    commands = pythonCommands ++ [commands.coreutils commands.grep];
    runtime.network = true;
    host.setup = ''cp ${./ipv6-bind-check.py} "$WASIX_TEST_ROOT/check.py"'';
    script = ''
      python${pyVer} check.py | tee out.log
      grep -q IPV6_OK out.log
    '';
  };
})
