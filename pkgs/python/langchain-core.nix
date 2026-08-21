# langchain-core 0.3 caps packaging<26 and the set ships 26.2, so a rebased 0.3
# takes the packaging history entry that satisfies it.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
  replaceInputsByName,
}:
exposeExtendedPackage (lib.optionalAttrs (lib.versionOlder package.version "1") {
    propagatedBuildInputs = replaceInputsByName {
      packaging = packages.sameProfile.packaging.versions."25.0";
    };
  }
  // lib.optionalAttrs (lib.versionOlder package.version "1.5.4") {
    patches = [./patches/langchain-core-pydantic-default.patch];
  }
  // {
    # The guest cannot execute its Python Wasm binary through host subprocess APIs.
    disabledTests = ["test_importable_all_via_subprocess"];
  })
