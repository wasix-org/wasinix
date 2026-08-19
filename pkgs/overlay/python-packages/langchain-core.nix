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
  }
  // {
    patches = [./patches/langchain-core-pydantic-default.patch];
    # The guest cannot execute its Python Wasm binary through host subprocess APIs.
    disabledTests = ["test_importable_all_via_subprocess"];
  })
pyprev.langchain-core
