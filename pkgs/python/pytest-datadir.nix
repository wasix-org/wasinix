{
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.pytest-datadir {
  # pytest-datadir declares pytest as a runtime dependency in wheel metadata.
  propagatedBuildInputs = [pyfinal.pytest];
}
