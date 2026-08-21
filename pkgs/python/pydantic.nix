# nixpkgs carries a pytest-9.1 compat patch for the test suite, cut against the
# current release, so its hunks miss on an older src. Cross builds never run the
# tests, so a history version does without it.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
  dropInputsByName,
  replaceInputsByName,
}:
exposeExtendedPackage (
  lib.optionalAttrs ((package.passthru.wasix.historySpec or null) != null) {
    patches = _: [];
    propagatedBuildInputs =
      if lib.versionOlder package.version "2"
      then
        dropInputsByName [
          "pydantic-core"
          "annotated-types"
          "typing-inspection"
        ]
      else
        replaceInputsByName (
          lib.optionalAttrs (lib.versionOlder package.version "2.11")
          {pydantic-core = packages.sameProfile.pydantic-core.versions."2.27.2";}
        );
  }
  // {
    passthru = old:
      old
      // {
        wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.hypothesis packages.sameProfile.pytest-mock packages.sameProfile.dirty-equals packages.sameProfile.jsonschema packages.sameProfile.inline-snapshot];
      };
    disabledTestPaths = ["tests/pydantic_core/serializers/test_functions.py"];
    disabledTests = ["test_dataclass_import" "test_import_pydantic" "test_import_base_model" "test_leak_dataclass"];
    pytestFlags = ["-W" "ignore::pytest.PytestUnknownMarkWarning"];
  }
)
