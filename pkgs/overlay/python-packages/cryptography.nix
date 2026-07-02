# cryptography for wasix. maturin/pyo3 wheel with a `cc`-crate OpenSSL shim. CC → the wasix cc
# so the shim cross-compiles; OPENSSL_NO_VENDOR to link our cross openssl;
# CFLAGS=-fwasm-exceptions (ehpic PIC needs wasm-EH); plus the shared maturin/pyo3 wiring
# (PYO3_CROSS_LIB_DIR, pyo3/extension-module, target-lexicon dl env — see lib/rust.nix).
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
    env = {
      CC = "${final.stdenv.cc}/bin/${final.stdenv.cc.targetPrefix}cc";
      OPENSSL_NO_VENDOR = "1";
      PYO3_CROSS_LIB_DIR = rust.pyo3CrossLibDir;
      CFLAGS = "-fwasm-exceptions";
    };
    maturinBuildFlags = ["--features" "pyo3/extension-module"];
  }
  pyprev.cryptography
