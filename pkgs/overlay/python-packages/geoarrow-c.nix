{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.geoarrow-c {
  passthru.wasinix.checks.captured.broken = "extension exceptions trap in _Unwind_RaiseException";
}
