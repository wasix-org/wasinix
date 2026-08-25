# The grammar parser is regenerated from antlr4's jar, whose path nixpkgs
# substitutes into a patch. Evaluating the wasm antlr4 fails ("Unsupported
# platform: wasip1"), and the jar runs on the build platform anyway.
{
  exposePackage,
  extendPackage,
  packages,
  package,
  pkgs,
}:
exposePackage (
  extendPackage (package.override {antlr4 = pkgs.buildPackages.antlr4;}) {
    # Preserve nixpkgs' pytest 8.3 pin and expose setuptools to build-helper tests.
    passthru.wasixDeclaredCheckInputs = [
      packages.sameProfile.pytest8_3CheckHook
      packages.sameProfile.setuptools
    ];
  }
)
