# fastapi 0.115 caps starlette<0.47 and the set ships 1.3.1, so a rebased 0.115
# takes the starlette history entry that satisfies it instead of the current one.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (lib.optionalAttrs (lib.versionOlder pyprev.fastapi.version "0.116") {
  propagatedBuildInputs = helpers.replaceInputsByName {
    starlette = pyfinal.starlette_0_46_2;
  };
})
pyprev.fastapi
