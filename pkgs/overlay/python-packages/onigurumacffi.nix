# The cffi build step runs on the build host, so it needs that interpreter's
# _cffi_backend rather than the wasm one.
{
  wasixPython,
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.onigurumacffi {
  nativeBuildInputs = [wasixPython.pythonOnBuildForHost.pkgs.cffi];
}
