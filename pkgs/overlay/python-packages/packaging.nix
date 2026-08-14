# nixpkgs does not run packaging's suite; opt in. Pure Python, except for
# property tests whose slow strategies are not useful under emulation.
{
  pyfinal,
  pyprev,
  ...
}:
pyprev.packaging.overridePythonAttrs (old: {
  passthru =
    (old.passthru or {})
    // {
      wasix = ((old.passthru or {}).wasix or {}) // {installCheck = true;};
      wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.pretend pyfinal.tomli-w pyfinal.hypothesis];
    };
  disabledTestPaths = (old.disabledTestPaths or []) ++ ["tests/property"];
  pytestFlags =
    (old.pytestFlags or [])
    ++ ["-W" "ignore::pytest.PytestRemovedIn10Warning"];
})
