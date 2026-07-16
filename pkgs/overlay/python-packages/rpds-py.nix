# rpds-py for wasix. maturin/pyo3 wheel (persistent data structures; jsonschema
# core). Same maturin-on-wasix wiring as jiter (cross sysconfig + extension-module).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
}
pyprev.rpds-py
