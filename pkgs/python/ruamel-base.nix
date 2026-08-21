# ruamel.base for wasix. setuptools names its namespace-package .pth after the
# interpreter, so the two builds differ by that filename alone.
{
  exposeExtendedPackage,
  package,
}:
exposeExtendedPackage {
  passthru = package.passthru // {wasix = {interpreterSpecific = true;};};
}
