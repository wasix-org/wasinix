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
helpers.libTweaks (
  lib.optionalAttrs ((pyprev.pydantic.passthru.wasix.historySpec or null) != null) {
    patches = _: [];
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
  }
  // {
    passthru = old:
      old
      // {
        wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.hypothesis pyfinal.pytest-mock pyfinal.dirty-equals pyfinal.jsonschema pyfinal.inline-snapshot];
      };
    disabledTestPaths = ["tests/pydantic_core/serializers/test_functions.py"];
    disabledTests = ["test_dataclass_import" "test_import_pydantic" "test_import_base_model" "test_leak_dataclass"];
    pytestFlags = ["-W" "ignore::pytest.PytestUnknownMarkWarning"];
  }
)
pyprev.pydantic
