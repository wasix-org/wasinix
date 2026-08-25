# No suite: the tests live inside the package, so pytest imports the source
# certifi, and they assert on cacert.pem, present only in the installed copy.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.checks.captured.install = false;
}
