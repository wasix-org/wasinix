# ml-dtypes' setup.py imports numpy at top level for get_include(), which the
# build host cannot do with the wasm numpy; its C headers are arch-independent.
{
  wasixPython,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  nativeBuildInputs = [wasixPython.pythonOnBuildForHost.pkgs.numpy];
}
pyprev.ml-dtypes
