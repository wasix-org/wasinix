{exposeExtendedPackage}:
exposeExtendedPackage {
  pytestFlags = ["--deselect=tests/test_parallel.py::ParallelTest::test_parallel_primegen"];
}
