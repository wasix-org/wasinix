# uuid-utils for wasix. maturin/pyo3 wheel (fast UUIDs; langchain/langgraph ids).
# It compiles getrandom 0.3 and 0.4, neither of which recognises our target;
# both have a fork-free wasi_p1 backend (raw preview1 random_get), so a vendor
# patch routes our env there. No getrandom fork, [patch.crates-io], or shipped
# lock needed — just the two vendor patches on nixpkgs' cargoDeps.
{
  pyprev,
  final,
  helpers,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
in
  helpers.libTweaks {
    cargoDeps = cd: rust.patchVendoredGetrandomWasi (rust.patchVendoredTargetLexiconDl cd);
    env.PYO3_CROSS_LIB_DIR = rust.pyo3CrossLibDir;
    maturinBuildFlags = ["--features" "pyo3/extension-module"];
  }
  pyprev.uuid-utils
