# setup.py imports numpy for get_include(), which the build host cannot do with
# the wasm numpy; its C headers are arch-independent.
{
  wasixPython,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  nativeBuildInputs = [wasixPython.pythonOnBuildForHost.pkgs.numpy];
  passthru.wasix.emulatedCheck.broken = "input-modification tests trap on integer division by zero";
}
pyprev.bottleneck
