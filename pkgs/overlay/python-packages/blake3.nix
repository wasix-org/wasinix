{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.emulatedCheck.broken = "mmap is unsupported by the Python runtime";
}
pyprev.blake3
