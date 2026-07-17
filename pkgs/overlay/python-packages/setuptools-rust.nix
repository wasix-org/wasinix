# setuptools-rust for wasix. PYO3_CROSS_LIB_DIR is set for every pyo3 wheel (maturin and
# setuptools-rust) by the python's buildPythonPackage (packages/python3/package.nix), so this
# override only adds the setuptools-rust-specific CARGO_BUILD_TARGET + linker.
{
  pyprev,
  final,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
in
  pyprev.setuptools-rust.overrideAttrs (old: {
    # setuptools-rust wheels skip maturinBuildHook, so propagate the vendor-patch hook here too.
    propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [final.rustPlatform.wasixVendorPatchHook];
    # cargoSetupHook sets a linker only for the stock rustcTarget, not our custom cargoBuildTarget,
    # and its linker is the clang cc wrapper, wrong for rustc's wasm-ld.
    #
    # setuptools-rust is a native build TOOL; splicing also puts it in NATIVE rust wheel builds (test
    # deps of e.g. scikit-build-core pull native bcrypt/cryptography). So self-gate on the rustc
    # target: apply the wasm cross config only when the active rustc actually has
    # wasm32-wasmer-wasi-dl (a wasix build); a native rustc lacks it and unconditionally forcing the
    # target fails (`rustc --print cfg --target wasm32-wasmer-wasi-dl` errors). Mirrors nixpkgs'
    # setuptools-rust-hook.sh + the gate (custom so we can add the condition; keep it in sync).
    setupHook = final.writeText "wasix-setuptools-rust-hook.sh" ''
      setuptoolsRustSetup() {
        if ! command -v cargoSetupPostPatchHook >/dev/null; then
          echo "ERROR: setuptools-rust has to be used alongside rustPlatform.cargoSetupHook!"
          exit 1
        fi
        rustc --print cfg --target "${rust.wasixRustDlTarget}" >/dev/null 2>&1 || return 0
        export CARGO_BUILD_TARGET="${rust.wasixRustDlTarget}"
        export CARGO_TARGET_WASM32_WASMER_WASI_DL_LINKER="${rust.rustLld}"
      }
      preConfigureHooks+=(setuptoolsRustSetup)
    '';
  })
