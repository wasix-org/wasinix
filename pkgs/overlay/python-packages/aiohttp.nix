# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree, not the installed package; importlib mode avoids it.
{
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  pytestFlags = ["--import-mode=importlib"];
  # Replaces the stashed check inputs: the inherited list drags cross builds
  # that cannot compile on wasix (bash-interactive via pexpect, paramiko).
  passthru = old:
    old
    // {
      # pytest-timeout owns the `timeout` ini option aiohttp sets
      wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.pytest-mock pyfinal.freezegun pyfinal.multidict pyfinal.yarl pyfinal.pytest-timeout];
      wasix = (old.wasix or {}) // {installCheck = false;};
    };
}
pyprev.aiohttp
