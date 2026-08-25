# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree, not the installed package; importlib mode avoids it.
{exposeExtendedPackage}:
exposeExtendedPackage {
  pytestFlags = ["--import-mode=importlib"];
}
