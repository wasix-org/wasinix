{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "the suite exceeds the 1200-second limit";
}
pyprev.hypothesis
