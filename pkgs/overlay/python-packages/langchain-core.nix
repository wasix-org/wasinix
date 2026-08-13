# langchain-core 0.3 caps packaging<26 and the set ships 26.2, so a rebased 0.3
# takes the packaging history entry that satisfies it.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (lib.optionalAttrs (lib.versionOlder pyprev.langchain-core.version "1") {
  propagatedBuildInputs = helpers.replaceInputsByName {
    packaging = pyfinal.packaging_25_0;
  };
})
pyprev.langchain-core
