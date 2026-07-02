# Rust counterpart to set/stdenv.nix: the profile's rustPlatform, built with a
# `cargo` shim that routes `cargo build` through cargo-wasix (which does the
# wasm-opt EH->exnref pass + target-features), so buildRustPackage works unchanged.
{
  lib,
  pkgsCross,
  wasixRustToolchain,
  cargo,
  cargoWasix,
}: let
  hostTriple = "x86_64-unknown-linux-gnu";
  rustLld = "${wasixRustToolchain}/lib/rustlib/${hostTriple}/bin/rust-lld";

  # `cargo build` goes through cargo-wasix, everything else (metadata, etc.)
  # to the real cargo.
  cargoWasixCargo = pkgsCross.buildPackages.writeShellScriptBin "cargo" ''
    if [ "''${1-}" = build ]; then
      shift
      # cargo-wasix wants a writable HOME/RUSTUP_HOME for its rustup state.
      export HOME="$PWD/.home"
      export RUSTUP_HOME="$HOME/.rustup"
      mkdir -p "$HOME" "$RUSTUP_HOME"
      exec ${cargoWasix}/bin/cargo-wasix wasix build "$@"
    fi
    exec ${cargo}/bin/cargo "$@"
  '';

  base = pkgsCross.makeRustPlatform {
    rustc = wasixRustToolchain;
    cargo = cargoWasixCargo;
  };

  # maturin rejects the wasix `dl` triple via target-lexicon. The wasix-org/maturin
  # fork was only a target-lexicon [patch] (source == upstream), so patch nixpkgs'
  # maturin's vendored target-lexicon instead.
  patchVendoredTargetLexiconDl = import ../lib/vendor-target-lexicon-dl.nix {
    pkgs = pkgsCross.buildPackages;
  };
  wasixMaturin = pkgsCross.buildPackages.maturin.overrideAttrs (old: {
    cargoDeps = patchVendoredTargetLexiconDl old.cargoDeps;
  });
in
  base
  // {
    # Expose cargo/rustc at top level so consumers avoid the deprecated rustPlatform.rust.* aliases.
    cargo = cargoWasixCargo;
    rustc = wasixRustToolchain;

    # Re-template maturinBuildHook for the dl target + rust-lld (nixpkgs bakes in
    # wasm32-wasip1, which our toolchain has no std for). Uses nixpkgs' own hook
    # file, not a vendored copy, so it tracks upstream and breaks loudly on a rework.
    maturinBuildHook =
      pkgsCross.makeSetupHook {
        name = "maturin-build-hook.sh";
        propagatedBuildInputs = [
          wasixMaturin
          cargoWasixCargo
          wasixRustToolchain
        ];
        substitutions = {
          rustcTargetSpec = "wasm32-wasmer-wasi-dl";
          setEnv = "CARGO_TARGET_WASM32_WASMER_WASI_DL_LINKER=${rustLld}";
        };
      }
      "${pkgsCross.path}/pkgs/build-support/rust/hooks/maturin-build-hook.sh";

    # Wasix defaults layered via lib.extendMkDerivation, NOT a lambda wrapper:
    # base.buildRustPackage is a __functor set whose attrs the cross-splice and
    # .override machinery read; a plain lambda loses them ("expected a set but
    # found a function").
    buildRustPackage = lib.extendMkDerivation {
      constructDrv = base.buildRustPackage;
      extendDrvArgs = finalAttrs: prevArgs: {
        # wasm can't run tests / installChecks on the build host.
        doCheck = false;
        doInstallCheck = false;
        # cargo-auditable would re-link via the host rustc; unneeded for wasm.
        auditable = false;

        # setEnv points CARGO_TARGET_<wasm>_LINKER at the wasi clang, which can't
        # take rustc's raw wasm-ld flags; override it with the toolchain's rust-lld
        # (the spec's native flavor). Flows through cargoBuildHook to cargo-wasix.
        cargoBuildFlags =
          ["--config" ''target.wasm32-wasmer-wasi.linker="${rustLld}"'']
          ++ (prevArgs.cargoBuildFlags or []);

        # Install each CLI cargo-wasix emitted (<name>.wasm; skip its .wasi/.rustc
        # intermediates).
        installPhase =
          prevArgs.installPhase or ''
            runHook preInstall
            mkdir -p "$out/bin"
            shopt -s nullglob
            for w in target/wasm32-wasmer-wasi/release/*.wasm; do
              case "$w" in *.wasi.wasm | *.rustc.wasm) continue ;; esac
              install -Dm644 "$w" "$out/bin/$(basename "$w")"
            done
            runHook postInstall
          '';

        # Default passthru.wasix.supportedProfiles to the profiles the rust
        # toolchain built std for (a package's own declaration wins). The
        # overlay's applyWasixMeta marks the package unsupported elsewhere;
        # preferredProfileOf derives the shipping profile (eh) from it.
        passthru =
          (prevArgs.passthru or {})
          // {
            wasix =
              {supportedProfiles = wasixRustToolchain.passthru.supportedProfiles;}
              // ((prevArgs.passthru or {}).wasix or {});
          };

        meta = (prevArgs.meta or {}) // {platforms = (prevArgs.meta or {}).platforms or lib.platforms.all;};
      };
    };
  }
