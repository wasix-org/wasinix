# Shared rust/pyo3 wheel helpers (bcrypt/cryptography/orjson/pydantic-core/setuptools-rust).
# In lib/ so the package loader skips it; import as `import ./lib/rust.nix {inherit final;}`.
{final}: rec {
  # pyo3's cross sysconfig dir. Use final.python3 (splice-stable to the wasix cross python),
  # NOT pyprev.python (splices to the native build python).
  pyo3CrossLibDir = "${final.python3}/lib/${final.python3.libPrefix}";

  # Extensions are PIC (ehpic) → the dl std target + its rust-lld. The rustlib dir is named by
  # the toolchain's build-host rust triple; derive it so it can't drift.
  wasixRustDlTarget = "wasm32-wasmer-wasi-dl";
  rustLld = "${final.rustc}/lib/rustlib/${final.stdenv.buildPlatform.rust.rustcTarget}/bin/rust-lld";

  # getrandom stays a fork (bcrypt/pydantic-core pull getrandom 0.3, no wasix backend upstream):
  # its backend adds a dep on the `wasix` crate, which the vendor-patch can't introduce.
  # target-lexicon needs no new dep, so it's vendored instead (patchVendoredTargetLexiconDl).
  getrandomForkBranch = "wasix-0.3.3";

  # Patch a wheel's cargoDeps so vendored target-lexicon parses the wasix `dl` env — no fork.
  # See ../../../lib/vendor-target-lexicon-dl.nix.
  patchVendoredTargetLexiconDl = import ../../../lib/vendor-target-lexicon-dl.nix {
    pkgs = final.buildPackages;
  };
}
