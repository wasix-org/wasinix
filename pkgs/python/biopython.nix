{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.biopython {
  passthru.wasinix.checks.captured.broken = "the custom suite requires undeclared NumPy";
}
