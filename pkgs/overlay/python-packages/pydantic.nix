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
  # 1.x predates the rewrite and needs none of the 2.x runtime trio.
  propagatedBuildInputs =
    if lib.versionOlder pyprev.pydantic.version "2"
    then
      helpers.dropInputsByName [
        "pydantic-core"
        "annotated-types"
        "typing-inspection"
      ]
    else
      helpers.replaceInputsByName (
        lib.optionalAttrs (lib.versionOlder pyprev.pydantic.version "2.11")
        {pydantic-core = pyfinal.pydantic-core_2_27_2;}
      );
})
pyprev.pydantic
