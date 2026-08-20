{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.sqlalchemy {
  passthru.wasinix.checks.captured.timeout = 7200;
}
