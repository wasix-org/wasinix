# pybase64's setup.py probes `cmake --version` to decide whether to build its
# accelerated C extension, falling back to pure Python if cmake is absent.
# The probe itself isn't wrapped in a try/except for FileNotFoundError, so a
# missing cmake crashes the build outright instead of falling back.
{
  pyprev,
  final,
  helpers,
  ...
}:
helpers.extendPackage pyprev.pybase64 {
  nativeBuildInputs = [final.buildPackages.cmake];
  # cmake's own setup hook would otherwise hijack configurePhase into `cmake
  # ..` at the top level; pybase64's real build backend is pypa/setuptools,
  # which only shells out to cmake itself, internally, as an accelerator.
  dontUseCmakeConfigure = true;
}
