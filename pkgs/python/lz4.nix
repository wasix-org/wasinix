# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree, not the installed package; importlib mode avoids it.
{exposeExtendedPackage}:
exposeExtendedPackage {
  # the *_2.py memory tests import psutil, which raises on wasix at collection
  # and aborts the whole run
  disabledTestPaths = ["tests/stream/test_stream_2.py" "tests/block/test_block_2.py"];
  pytestFlags =
    ["--import-mode=importlib"]
    # the large-data parametrisations fail with BrokenPipeError; siblings cover
    # the API
    ++ ["--deselect" "tests/block/test_block_0.py::test_2"]
    # lz4's addopts include -x; maxfail=0 (appended, so it wins) reports every
    # failure in one run
    ++ ["--maxfail=0"];
  passthru.wasinix.checks.captured = {
    shards = 4;
    timeout = 3600;
  };
}
