{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.emulatedCheck.broken = "extension exceptions trap in _Unwind_RaiseException";
}
pyprev.python-crfsuite
