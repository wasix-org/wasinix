{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.s3transfer {
  # This suite exercises multiprocessing rather than the normal transfer path.
  disabledTestPaths = ["tests/functional/test_processpool.py" "tests/unit/test_processpool.py"];
}
