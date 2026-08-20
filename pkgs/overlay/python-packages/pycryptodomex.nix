{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.pycryptodomex {
  # the wheel-shipped SelfTest suite in tests/upstream.nix replaces the derived
  # source-tree check (the source Cryptodome/ has no compiled modules)
  passthru.wasinix.checks.captured.install = false;
}
