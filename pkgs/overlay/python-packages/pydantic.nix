# nixpkgs carries a pytest-9.1 compat patch for the test suite, cut against the
# current release, so its hunks miss on an older src. Cross builds never run the
# tests, so a history version does without it.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (lib.optionalAttrs ((pyprev.pydantic.passthru.wasix.historySpec or null) != null) {
  patches = _: [];
  # 2.10.6 pins pydantic-core to its own release, which the set no longer ships.
  propagatedBuildInputs = ps:
    map (p:
      if (p.pname or "") == "pydantic-core" && lib.versionOlder pyprev.pydantic.version "2.11"
      then pyfinal.pydantic-core_2_27_2
      else p) (
      if ps == null
      then []
      else ps
    );
})
pyprev.pydantic
