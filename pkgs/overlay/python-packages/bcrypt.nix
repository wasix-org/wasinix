# bcrypt for wasix. getrandom 0.3 (RNG) has no wasix backend upstream, but its
# fork-free wasi_p1 backend does, so a vendor patch routes our env there.
# target-lexicon stays on crates.io + the `dl` vendor patch.
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
  }
  pyprev.bcrypt
