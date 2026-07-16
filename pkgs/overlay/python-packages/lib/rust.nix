# Shared rust wheel helpers (setuptools-rust; the maturin wheels take the dl target from the
# re-templated maturinBuildHook). In lib/ so the package loader skips it; import as
# `import ./lib/rust.nix {inherit final;}`. The pyo3 cross sysconfig dir is NOT here: it's a
# property of the python set building the wheel, derived from the `wasixPython` callArg (see
# packages/python3/package.nix).
{final}: rec {
  # Extensions are PIC (ehpic) → the dl std target + its rust-lld. The rustlib dir is named by
  # the toolchain's build-host rust triple; derive it so it can't drift.
  wasixRustDlTarget = "wasm32-wasmer-wasi-dl";
  rustLld = "${final.rustc}/lib/rustlib/${final.stdenv.buildPlatform.rust.rustcTarget}/bin/rust-lld";
}
