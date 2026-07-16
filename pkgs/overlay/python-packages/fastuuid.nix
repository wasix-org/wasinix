# fastuuid for wasix. maturin/pyo3 wheel (fast UUIDs; litellm request ids).
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
pyprev.fastuuid
