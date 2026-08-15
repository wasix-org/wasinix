{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.emulatedCheck.broken = "the custom suite requires undeclared NumPy";
}
pyprev.biopython
