{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "mmap is unsupported by the Python runtime";
}
pyprev.blake3
