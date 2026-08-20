{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.timeout = 3600;
}
pyprev.more-itertools
