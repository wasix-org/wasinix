{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The 6k-case suite exhausts Wasmer's call stack at one percent. Import and
  # wheel checks still exercise the extension module.
  passthru.wasinix.checks.captured.install = false;
}
pyprev.msgspec
