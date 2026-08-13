# pydantic-core for wasix. maturin/pyo3 wheel. pyo3 needs the cross sysconfig
# (PYO3_CROSS_LIB_DIR) and pyo3/extension-module forced on, else it emits
# `-l python3.13` and the cdylib link fails (no libpython at build time).
#
# 2.42 moved the project into the pydantic monorepo under pydantic-core/. An
# older entry fetches the standalone repo it lived in, whose tree root is the
# project itself.
{
  pyprev,
  helpers,
  lib,
  ...
}:
helpers.libTweaks ({
    maturinBuildFlags = ["--features" "pyo3/extension-module"];
  }
  // lib.optionalAttrs (lib.versionOlder pyprev.pydantic-core.version "2.42") {
    sourceRoot = "source";
  })
pyprev.pydantic-core
