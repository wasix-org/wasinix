# pydantic-core for wasix. Like bcrypt.nix, its getrandom 0.3 has no wasix backend → point it
# at the wasix-org fork and re-vendor; target-lexicon stays on crates.io + the `dl` patch. pyo3
# needs the cross sysconfig (PYO3_CROSS_LIB_DIR) and pyo3/extension-module forced on.
{
  pyprev,
  final,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
  patchedSrc = final.applyPatches {
    name = "pydantic-core-src-wasix-rust-deps";
    src = pyprev.pydantic-core.src;
    # fetchCargoVendor uses the lockfile as-is, so ship a lock regenerated for the fork.
    postPatch = ''
      cat >> Cargo.toml <<'EOF'

      [patch.crates-io]
      getrandom = { git = "https://github.com/wasix-org/getrandom.git", branch = "${rust.getrandomForkBranch}" }
      EOF
      cp ${./pydantic-core-Cargo.lock} Cargo.lock
    '';
  };
in
  pyprev.pydantic-core.overrideAttrs (old: {
    src = patchedSrc;
    cargoDeps = rust.patchVendoredTargetLexiconDl (final.rustPlatform.fetchCargoVendor {
      inherit (old) pname version;
      src = patchedSrc;
      hash = "sha256-lWE+vnktwXNLn8PM1RbmuwsuiEOBK1XmSQH5wNwSgpg=";
    });
    # else pyo3 emits `-l python3.13` and the cdylib link fails (no libpython at build time).
    maturinBuildFlags = (old.maturinBuildFlags or []) ++ ["--features" "pyo3/extension-module"];
    # maturin has no built-in sysconfig for the custom target; point pyo3 at the cross one.
    env = (old.env or {}) // {PYO3_CROSS_LIB_DIR = rust.pyo3CrossLibDir;};
  })
