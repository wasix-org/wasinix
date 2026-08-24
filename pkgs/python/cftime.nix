# setup.py imports numpy for get_include(), which the build host cannot do with
# the wasm numpy; its C headers are arch-independent.
{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  nativeBuildInputs = [packages.sameProfile.python.pythonOnBuildForHost.pkgs.numpy];
}
