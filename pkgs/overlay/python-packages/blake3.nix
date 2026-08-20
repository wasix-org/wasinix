{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.blake3 {
  passthru.wasinix.checks.captured.broken = "mmap is unsupported by the Python runtime";
}
