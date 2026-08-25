# rpds-py for wasix. maturin/pyo3 wheel (persistent data structures; jsonschema
# core). Same maturin-on-wasix wiring as jiter (cross sysconfig + extension-module).
{exposeExtendedPackage}:
exposeExtendedPackage {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
}
