{
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # pytest-datadir declares pytest as a runtime dependency in wheel metadata.
  propagatedBuildInputs = [pyfinal.pytest];
}
pyprev.pytest-datadir
