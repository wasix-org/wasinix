# asyncpg's test suite drives a real postgres, so nixpkgs takes the server as an
# argument and reaches into it for `doCheck` and `PGBIN`. Those force it to
# evaluate even though a cross build never runs the suite, and the server does
# not evaluate for wasm; point them at the build-platform one instead.
{
  pyprev,
  final,
  helpers,
  ...
}:
helpers.libTweaks {
  doCheck = false;
  # nothing runs them, and some do not evaluate for wasm
  nativeCheckInputs = _: [];
}
(pyprev.asyncpg.override {postgresql = final.buildPackages.postgresql;})
