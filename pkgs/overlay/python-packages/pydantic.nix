# nixpkgs carries a pytest-9.1 compat patch for the test suite, cut against the
# current release, so its hunks miss on an older src. Cross builds never run the
# tests, so a history version does without it.
{
  pyprev,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (lib.optionalAttrs ((pyprev.pydantic.passthru.wasix.historySpec or null) != null) {
  patches = _: [];
})
pyprev.pydantic
