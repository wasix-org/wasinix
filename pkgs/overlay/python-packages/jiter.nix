# jiter for wasix. maturin/pyo3 wheel (fast JSON parser; anthropic/openai core).
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
pyprev.jiter
