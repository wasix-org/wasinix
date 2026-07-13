# rpds-py for wasix. maturin/pyo3 wheel (persistent data structures; jsonschema
# core). Same maturin-on-wasix wiring as jiter: cross sysconfig +
# pyo3/extension-module, crates.io cargoDeps with the target-lexicon `dl` patch.
{
  pyprev,
  final,
  helpers,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
in
  helpers.libTweaks {
    cargoDeps = rust.patchVendoredTargetLexiconDl;
    env.PYO3_CROSS_LIB_DIR = rust.pyo3CrossLibDir;
    maturinBuildFlags = ["--features" "pyo3/extension-module"];
  }
  pyprev.rpds-py
