# fastuuid for wasix. maturin/pyo3 wheel (fast UUIDs; litellm request ids).
{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
  # Replaces the stashed check inputs: the inherited hypothesis is the
  # build-platform one, whose Rust _native the guest cannot import.
  passthru = old:
    old
    // {
      wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.hypothesis];
    };
}
