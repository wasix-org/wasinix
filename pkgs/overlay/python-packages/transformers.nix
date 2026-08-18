# transformers for wasix. Its extras resolve per interpreter, so the METADATA
# the two builds publish differs and cannot share one py3-none-any filename.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru = pyprev.transformers.passthru // {wasix = {interpreterSpecific = true;};};
}
pyprev.transformers
