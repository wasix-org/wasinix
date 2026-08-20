{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.black {
  # Formatter subprocess/editor coverage does not complete under WASIX.
  passthru.wasinix.checks.captured.install = false;
}
