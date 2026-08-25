# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree, not the installed package; importlib mode avoids it.
{exposeExtendedPackage}:
exposeExtendedPackage {
  pytestFlags = ["--import-mode=importlib"];
  # recurses deeply enough to exhaust the wasm call stack, killing the guest
  disabledTestPaths = ["tests/test_cfg.py"];
}
