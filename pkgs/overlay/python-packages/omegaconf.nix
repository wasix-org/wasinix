# The grammar parser is regenerated from antlr4's jar, whose path nixpkgs
# substitutes into a patch. Evaluating the wasm antlr4 fails ("Unsupported
# platform: wasip1"), and the jar runs on the build platform anyway.
{
  pyprev,
  final,
  ...
}:
pyprev.omegaconf.override {antlr4 = final.buildPackages.antlr4;}
