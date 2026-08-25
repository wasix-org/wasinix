{
  exposeExtendedPackage,
  packages,
  replaceInputsByName,
}: let
  formatCheckingUfmt = packages.sameProfile.ufmt.overridePythonAttrs (old: {
    dependencies = replaceInputsByName {black = packages.sameProfile.black.versions."25.1.0";} old.dependencies;
  });
in
  exposeExtendedPackage {
    patches = [./patches/wasix-execution.patch];
    passthru.wasixDeclaredCheckInputs = [packages.sameProfile.hypothesmith packages.sameProfile.pytestCheckHook formatCheckingUfmt];
  }
