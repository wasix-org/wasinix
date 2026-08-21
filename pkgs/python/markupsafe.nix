# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree rather than the installed package.
{exposeExtendedPackage}:
exposeExtendedPackage {
  pytestFlags = ["--import-mode=importlib"];
}
