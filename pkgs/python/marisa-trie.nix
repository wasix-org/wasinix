{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.marisa-trie {
  passthru.wasinix.checks.captured.broken = "extension exceptions trap in _Unwind_RaiseException";
}
