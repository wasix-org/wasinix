{
  pyprev,
  helpers,
  lib,
  ...
}:
helpers.libTweaks ({
    maturinBuildFlags = ["--features" "pyo3/extension-module"];
    patches = lib.optionals (lib.versionAtLeast pyprev.pydantic-core.version "2.46") [
      ./patches/wasm-function-recursion.patch
    ];
  }
  // lib.optionalAttrs (lib.versionOlder pyprev.pydantic-core.version "2.42") {
    sourceRoot = "source";
  })
pyprev.pydantic-core
