# ruamel.base for wasix. setuptools names its namespace-package .pth after the
# interpreter, so the two builds differ by that filename alone.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.publication.interpreterSpecific = true;
}
