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
  # CPython's configure disables ipv6 for WASI, where wasi-libc has no
  # AF_INET6; WASIX has it, and getaddrinfo hands out AF_INET6 either way.
  ipv6-bind = testLib.mkWasixRun {
    name = "python${tag}-ipv6-bind";
    wasixPkgs = [python];
    wasmerArgs = ["--net"];
    script = ''
      cp ${./ipv6-bind-check.py} check.py
      python${pyVer} check.py | tee out.log
      grep -q IPV6_OK out.log
    '';
  };
})
