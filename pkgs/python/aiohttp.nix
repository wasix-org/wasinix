# Pytest's default import mode puts the rootdir on sys.path, so the suite
# imports the source tree, not the installed package; importlib mode avoids it.
{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  pytestFlags = ["--import-mode=importlib"];
  # Replaces the stashed check inputs: the inherited list drags cross builds
  # that cannot compile on wasix (bash-interactive via pexpect, paramiko).
  passthru = old:
    old
    // {
      # pytest-timeout owns the `timeout` ini option aiohttp sets
      wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.pytest-mock packages.sameProfile.freezegun packages.sameProfile.multidict packages.sameProfile.yarl packages.sameProfile.pytest-timeout];
      wasinix = (old.wasinix or {}) // {checks.captured.install = false;};
    };
}
