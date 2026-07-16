# fastuuid for wasix. maturin/pyo3 wheel (fast UUIDs; litellm request ids).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
}
pyprev.fastuuid
