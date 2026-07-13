# tiktoken for wasix. setuptools-rust/pyo3 wheel (BPE tokenizer; openai token
# counting). The cross target + linker come from our re-templated setuptools-rust
# hook (see setuptools-rust.nix); it has no getrandom, so only the target-lexicon
# `dl` patch on the vendored deps is needed.
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
  }
  pyprev.tiktoken
