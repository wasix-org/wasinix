# setup.py imports numpy for get_include(), which the build host cannot do with
# the wasm numpy; its C headers are arch-independent.
{
  wasixPython,
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.bottleneck {
  nativeBuildInputs = [wasixPython.pythonOnBuildForHost.pkgs.numpy];
  passthru.wasinix.checks.captured.broken = "input-modification tests trap on integer division by zero";
}
