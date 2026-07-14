# fastuuid for wasix. maturin/pyo3 wheel (fast UUIDs; litellm request ids).
{
  pyprev,
  final,
  helpers,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
in
  helpers.libTweaks {
    env.PYO3_CROSS_LIB_DIR = rust.pyo3CrossLibDir;
    maturinBuildFlags = ["--features" "pyo3/extension-module"];
  }
  pyprev.fastuuid
