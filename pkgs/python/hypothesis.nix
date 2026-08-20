{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.hypothesis {
  passthru.wasinix.checks.captured.broken = "the suite exceeds the 1200-second limit";
}
