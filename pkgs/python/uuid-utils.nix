# uuid-utils for wasix. maturin/pyo3 wheel (fast UUIDs; langchain/langgraph ids).
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.uuid-utils {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
  # forks and re-execs the shebanged interpreter in-guest, which re-enters the
  # wasix-run stub (WASIX-TODO.md)
  disabledTests = ["test_reseed_is_called_when_forking"];
}
