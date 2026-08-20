# ruamel.base for wasix. setuptools names its namespace-package .pth after the
# interpreter, so the two builds differ by that filename alone.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.ruamel-base {
  passthru = pyprev.ruamel-base.passthru // {wasix = {interpreterSpecific = true;};};
}
