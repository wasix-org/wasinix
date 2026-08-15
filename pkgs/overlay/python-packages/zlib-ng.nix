{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.emulatedCheck.broken = "compliance tests require CPython's test package";
}
pyprev.zlib-ng
