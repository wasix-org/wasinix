# nixpkgs does not run packaging's suite; opt in. Pure Python, except for
# property tests whose slow strategies are not useful under emulation.
{
  exposePackage,
  packages,
  package,
}:
exposePackage (
  package.overridePythonAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        wasinix = ((old.passthru or {}).wasinix or {}) // {checks.captured.install = true;};
        wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.pretend packages.sameProfile.tomli-w packages.sameProfile.hypothesis];
      };
    disabledTestPaths = (old.disabledTestPaths or []) ++ ["tests/property"];
    pytestFlags =
      (old.pytestFlags or [])
      ++ ["-W" "ignore::pytest.PytestRemovedIn10Warning"];
  })
)
