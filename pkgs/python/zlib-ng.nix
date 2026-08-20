{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.zlib-ng {
  passthru.wasinix.checks.captured.broken = "compliance tests require CPython's test package";
}
