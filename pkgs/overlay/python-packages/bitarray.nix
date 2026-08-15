{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.emulatedCheck.broken = "WASIX reports bitarray objects as hashable";
}
pyprev.bitarray
