{
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # pytest-lazy-fixture declares pytest as a runtime dependency in wheel metadata.
  propagatedBuildInputs = [pyfinal.pytest];
}
pyprev.pytest-lazy-fixture
