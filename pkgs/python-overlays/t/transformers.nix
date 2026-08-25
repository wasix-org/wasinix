# transformers for wasix. Its extras resolve per interpreter, so the METADATA
# the two builds publish differs and cannot share one py3-none-any filename.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.publication.interpreterSpecific = true;
}
