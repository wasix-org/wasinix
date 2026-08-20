# The grammar parser is regenerated from antlr4's jar, whose path nixpkgs
# substitutes into a patch. Evaluating the wasm antlr4 fails ("Unsupported
# platform: wasip1"), and the jar runs on the build platform anyway.
{
  pyprev,
  pyfinal,
  final,
  helpers,
  ...
}:
helpers.extendPackage (pyprev.hydra-core.override {antlr4 = final.buildPackages.antlr4;}) {
  # Preserve nixpkgs' pytest 8.3 pin and expose setuptools to build-helper tests.
  passthru.wasixDeclaredCheckInputs = [
    pyfinal.pytest8_3CheckHook
    pyfinal.setuptools
  ];
}
