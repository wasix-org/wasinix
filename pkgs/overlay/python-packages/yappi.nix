{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "the context-statistics tests do not complete";
}
pyprev.yappi
