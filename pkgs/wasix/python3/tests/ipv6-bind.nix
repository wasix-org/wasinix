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
  # CPython's configure disables ipv6 for WASI, where wasi-libc has no
  # AF_INET6; WASIX has it, and getaddrinfo hands out AF_INET6 either way.
  ipv6-bind = harnesses.hostShell {
    name = "python${tag}-ipv6-bind";
    wasixCommands = pythonCommands;
    wasmerArgs = ["--net"];
    script = ''
      cp ${./ipv6-bind-check.py} check.py
      python${pyVer} check.py | tee out.log
      grep -q IPV6_OK out.log
    '';
  };
})
