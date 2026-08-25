{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  # Omit objgraph, whose Graphviz closure cannot build for WASIX.
  passthru.wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.pytest-cov-stub];
  disabledTestPaths = [
    "tests/isolated"
    "tests/test_multidict_benchmarks.py"
    "tests/test_views_benchmarks.py"
  ];
  # The harness invokes the omitted isolated leak programs as subprocesses.
  disabledTests = ["test_leak"];
}
