{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "extension exceptions trap in _Unwind_RaiseException";
}
pyprev.python-crfsuite
