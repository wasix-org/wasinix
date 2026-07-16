# jiter for wasix. maturin/pyo3 wheel (fast JSON parser; anthropic/openai core).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
}
pyprev.jiter
