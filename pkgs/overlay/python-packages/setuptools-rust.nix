# setuptools-rust for wasix. Its hook defaults PYO3_CROSS_LIB_DIR to
# python.pythonOnTargetForTarget, whose closure pulls a cross bash that can't build (fork()
# only on `off`). Re-template nixpkgs' own hook (by path, so it tracks upstream) with our
# wasm python's lib dir.
{
  pyprev,
  final,
  wasixPython,
  ...
}: let
  rust = import ./lib/rust.nix {inherit final;};
in
  pyprev.setuptools-rust.overrideAttrs (old: {
    # setuptools-rust wheels skip maturinBuildHook, so propagate the vendor-patch hook here too.
    propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [final.rustPlatform.wasixVendorPatchHook];
    # cargoSetupHook sets a linker only for the stock rustcTarget, not our custom
    # cargoBuildTarget, and its linker is the clang cc wrapper, wrong for rustc's wasm-ld.
    setupHook = final.replaceVars "${final.path}/pkgs/development/python-modules/setuptools-rust/setuptools-rust-hook.sh" {
      pyLibDir = wasixPython.crossLibDir;
      cargoBuildTarget = rust.wasixRustDlTarget;
      cargoLinkerVar = "WASM32_WASMER_WASI_DL";
      targetLinker = rust.rustLld;
    };
  })
