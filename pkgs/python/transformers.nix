# transformers for wasix. Its extras resolve per interpreter, so the METADATA
# the two builds publish differs and cannot share one py3-none-any filename.
{
  exposeExtendedPackage,
  package,
}:
exposeExtendedPackage {
  passthru = package.passthru // {wasix = {interpreterSpecific = true;};};
}
