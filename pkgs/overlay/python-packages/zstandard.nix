# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree, not the installed package; importlib mode avoids it.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  pytestFlags = ["--import-mode=importlib"];
  # No suite: the extension trips the wasm indirect-call trap mid-run, killing
  # the session (WASIX-TODO.md).
  passthru.wasix.installCheck = false;
}
pyprev.zstandard
