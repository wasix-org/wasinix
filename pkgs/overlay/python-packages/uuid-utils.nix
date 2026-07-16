# uuid-utils for wasix. maturin/pyo3 wheel (fast UUIDs; langchain/langgraph ids).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
}
pyprev.uuid-utils
