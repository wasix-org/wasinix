{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  pytestFlags = ["--deselect=tests/test_parallel.py::ParallelTest::test_parallel_primegen"];
}
pyprev.rsa
