{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.python-crfsuite {
  passthru.wasinix.checks.captured.broken = "extension exceptions trap in _Unwind_RaiseException";
}
