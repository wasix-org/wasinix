{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # This suite exercises multiprocessing rather than the normal transfer path.
  disabledTestPaths = ["tests/functional/test_processpool.py" "tests/unit/test_processpool.py"];
}
pyprev.s3transfer
