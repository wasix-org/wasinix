{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.more-itertools {
  passthru.wasinix.checks.captured.timeout = 3600;
}
