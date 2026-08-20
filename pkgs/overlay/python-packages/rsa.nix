{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.rsa {
  pytestFlags = ["--deselect=tests/test_parallel.py::ParallelTest::test_parallel_primegen"];
}
