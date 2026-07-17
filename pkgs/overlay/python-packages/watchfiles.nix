# watchfiles for wasix. maturin/pyo3 wheel (uvicorn --reload file watching).
# notify has no wasi backend; it falls back to PollWatcher, which is the right
# semantics here anyway (no inotify on wasix).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
}
pyprev.watchfiles
