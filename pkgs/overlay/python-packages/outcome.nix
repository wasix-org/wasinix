# nixpkgs does not run outcome's suite; opt in. test_async needs a trio event
# loop, which pulls the async stack wasix cannot yet drive.
{
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # check inputs go through the stash; input-list additions never reach the
  # check derivation (see packaging.nix)
  passthru = old:
    old
    // {
      wasix = (old.wasix or {}) // {installCheck = true;};
      wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook];
    };
  disabledTestPaths = ["tests/test_async.py"];
}
pyprev.outcome
