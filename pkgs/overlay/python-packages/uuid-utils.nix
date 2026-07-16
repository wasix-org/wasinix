# uuid-utils for wasix. maturin/pyo3 wheel (fast UUIDs; langchain/langgraph ids).
{
  pyprev,
  wasixPython,
  helpers,
  ...
}:
helpers.libTweaks {
  env.PYO3_CROSS_LIB_DIR = wasixPython.crossLibDir;
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
}
pyprev.uuid-utils
