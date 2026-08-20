{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.yappi {
  passthru.wasinix.checks.captured.broken = "the context-statistics tests do not complete";
}
