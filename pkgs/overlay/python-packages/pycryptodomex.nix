{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # the wheel-shipped SelfTest suite in tests/upstream.nix replaces the derived
  # source-tree check (the source Cryptodome/ has no compiled modules)
  passthru.wasix.installCheck = false;
}
pyprev.pycryptodomex
