# multiprocess for wasix. It vendors the stdlib multiprocessing of the
# interpreter it was built for, so the two builds carry different sources and
# cannot share one py3-none-any filename.
{
  exposeExtendedPackage,
  package,
}:
exposeExtendedPackage {
  passthru = package.passthru // {wasix = {interpreterSpecific = true;};};
}
