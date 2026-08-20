{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "the custom suite requires undeclared NumPy";
}
pyprev.biopython
