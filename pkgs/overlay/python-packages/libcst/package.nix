{
  pyprev,
  pyfinal,
  helpers,
  ...
}: let
  formatCheckingUfmt = pyfinal.ufmt.overridePythonAttrs (old: {
    dependencies = helpers.replaceInputsByName {black = pyfinal.black_25_1_0;} old.dependencies;
  });
in
  helpers.libTweaks {
    patches = [./patches/wasix-execution.patch];
    passthru.wasixDeclaredCheckInputs = [pyfinal.hypothesmith pyfinal.pytestCheckHook formatCheckingUfmt];
  }
  pyprev.libcst
