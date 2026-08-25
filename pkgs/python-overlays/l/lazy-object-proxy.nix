{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  passthru.wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.pytest-benchmark];
}
