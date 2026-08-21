# debugpy for wasix. Its preBuild compiles the pydevd attach-to-process helper,
# which injects into a target process via ptrace/dlopen; wasm has neither, and
# skipping it costs only attach-to-running-process.
{exposeExtendedPackage}:
exposeExtendedPackage {
  preBuild = _: "";
  # Eight xdist workers block under emulation until the outer 1200-second cap.
  passthru.wasinix.checks.captured.install = false;
}
