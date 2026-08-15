{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.emulatedCheck.broken = "the suite exceeds the 1200-second limit";
}
pyprev.hypothesis
