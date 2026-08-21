# The cffi build step runs on the build host, so it needs that interpreter's
# _cffi_backend rather than the wasm one.
{
  exposeExtendedPackage,
  packages,
  pkgs,
}:
exposeExtendedPackage {
  nativeBuildInputs = [packages.sameProfile.python.pythonOnBuildForHost.pkgs.cffi];
}
