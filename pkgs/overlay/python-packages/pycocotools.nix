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
}
pyprev.pycocotools
