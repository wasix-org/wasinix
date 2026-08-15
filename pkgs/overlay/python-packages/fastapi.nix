# fastapi 0.115 caps starlette<0.47 and the set ships 1.3.1, so a rebased 0.115
# takes the starlette history entry that satisfies it instead of the current one.
{
  pyprev,
  pyfinal,
  wasixPython,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (
  lib.optionalAttrs (lib.versionOlder pyprev.fastapi.version "0.116") {
    propagatedBuildInputs = helpers.replaceInputsByName {
      starlette = pyfinal.starlette_0_46_2;
    };
  }
  // {
    disabledTests = [
      "test_frontend_respects_root_path"
      "test_required_list_alias_by_name"
    ];
  }
  // lib.optionalAttrs (lib.versionOlder wasixPython.pythonVersion "3.14") {
    passthru.wasix.emulatedCheck.broken = "the runtime exits while running test_frontend";
  }
)
pyprev.fastapi
