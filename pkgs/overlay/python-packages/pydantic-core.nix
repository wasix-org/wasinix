# pydantic-core for wasix. maturin/pyo3 wheel. pyo3 needs the cross sysconfig
# (PYO3_CROSS_LIB_DIR) and pyo3/extension-module forced on, else it emits
# `-l python3.13` and the cdylib link fails (no libpython at build time).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
}
pyprev.pydantic-core
