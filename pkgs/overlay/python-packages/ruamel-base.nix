# ruamel.base for wasix. setuptools names its namespace-package .pth after the
# interpreter, so the two builds differ by that filename alone.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru = pyprev.ruamel-base.passthru // {wasix = {interpreterSpecific = true;};};
}
pyprev.ruamel-base
