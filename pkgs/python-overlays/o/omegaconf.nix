# The grammar parser is regenerated from antlr4's jar, whose path nixpkgs
# substitutes into a patch. Evaluating the wasm antlr4 fails ("Unsupported
# platform: wasip1"), and the jar runs on the build platform anyway.
{
  exposePackage,
  package,
  pkgs,
}:
exposePackage (
  package.override {antlr4 = pkgs.buildPackages.antlr4;}
)
