{
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.pytest-lazy-fixture {
  # pytest-lazy-fixture declares pytest as a runtime dependency in wheel metadata.
  propagatedBuildInputs = [pyfinal.pytest];
}
