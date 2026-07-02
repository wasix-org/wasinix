# bcrypt for wasix. getrandom 0.3 has no wasix RNG backend upstream, so
# bcrypt-wasix-rust-deps.patch points it at the wasix-org getrandom fork and bcrypt-Cargo.lock
# pins it. target-lexicon stays on crates.io + patchVendoredTargetLexiconDl (no fork).
{
  pyprev,
  final,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
  patchedSrc = final.applyPatches {
    name = "bcrypt-src-wasix-rust-deps";
    src = pyprev.bcrypt.src;
    patches = [./patches/bcrypt-wasix-rust-deps.patch];
    # fetchCargoVendor uses the lockfile as-is, so ship a lock regenerated for the fork.
    postPatch = "cp ${./bcrypt-Cargo.lock} src/_bcrypt/Cargo.lock";
  };
in
  pyprev.bcrypt.overrideAttrs (old: {
    src = patchedSrc;
    cargoDeps = rust.patchVendoredTargetLexiconDl (final.rustPlatform.fetchCargoVendor {
      inherit (old) pname version cargoRoot;
      src = patchedSrc;
      hash = "sha256-/r0oTtSt3k8pVcupb8bnC5pJJmxptoSxNWXldZbVC7U=";
    });
  })
