# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree, not the installed package; importlib mode avoids it.
{exposeExtendedPackage}:
exposeExtendedPackage {
  # both files run a real listening server over loopback; the guest cannot
  # bind a listener, so every test touching the fixture fails
  disabledTestPaths = ["tests/test_testserver.py" "tests/test_lowlevel.py"];
  pytestFlags = ["--import-mode=importlib"];
}
