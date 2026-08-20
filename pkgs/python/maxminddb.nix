{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.maxminddb {
  passthru.wasinix.checks.captured.broken = "multiprocessing has no fork context";
}
