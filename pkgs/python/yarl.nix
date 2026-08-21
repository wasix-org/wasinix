# nixpkgs drops nativeCheckInputs on cross along with checkPhase, so the
# runner must be named here for the suite to exist.
{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  # yarl's addopts say `-n auto`, and xdist workers crash nondeterministically;
  # -n 0 (appended, so it wins) serialises without touching addopts
  pytestFlags = ["-n" "0"];
  # Replaces the stashed check inputs: the inherited hypothesis is the
  # build-platform one, whose Rust _native the guest cannot import.
  passthru = old:
    old
    // {
      # cov-stub: yarl's addopts pass --cov
      # xdist must stay installed (addopts pass --numprocesses); -n 0 keeps
      # the run in one guest
      wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.hypothesis packages.sameProfile.pytest-asyncio packages.sameProfile.pytest-cov-stub packages.sameProfile.pytest-xdist];
    };
}
