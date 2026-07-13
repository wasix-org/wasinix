# fastuuid for wasix. maturin/pyo3 wheel (fast UUIDs; litellm request ids). Its
# uuid/rand deps pull getrandom 0.3/0.4, neither of which recognises our target;
# both have a fork-free wasi_p1 backend (raw preview1 random_get), so a vendor
# patch routes our env there. Fork-free avoids the git [patch.crates-io] source
# that tripped fetchCargoVendor's offline cargo-lock consistency check.
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
  pyprev.fastuuid
