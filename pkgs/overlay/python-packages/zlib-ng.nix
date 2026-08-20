{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "compliance tests require CPython's test package";
}
pyprev.zlib-ng
