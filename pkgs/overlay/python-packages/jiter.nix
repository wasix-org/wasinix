# jiter for wasix. maturin/pyo3 wheel (fast JSON parser; anthropic/openai core).
# jiter pulls getrandom 0.3 through ahash's runtime-rng; getrandom 0.3 doesn't
# recognise our target, but its fork-free wasi_p1 backend (raw preview1
# random_get) does, so a vendor patch routes our env there. No fork,
# [patch.crates-io], or shipped lock needed -- just the two vendor patches on
# nixpkgs' cargoDeps (as uuid-utils/fastuuid).
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
  pyprev.jiter
