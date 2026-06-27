# The Rust counterpart to mk-wasix-stdenv: wires cargo-wasix in as the profile's
# `rustPlatform`, so wasix Rust crates build + package transparently via
# `rustPlatform.buildRustPackage` (just `prev.X`), the way C/C++ build via the wasixcc
# stdenv. Everything generic to a wasix Rust CLI lives here; package files carry only real
# per-package tweaks, via the same libTweaks/overrideAttrs C uses.
#
# cargo-wasix is the upstream tool and does essential work beyond `cargo build`: its
# wasm-opt pass translates EH→exnref (what wasmer runs), enables threads/bulk-memory/
# reference-types and applies the target-features. We integrate it the way buildRustPackage
# is built for — `cargo` is one of its inputs (see build-rust-package/default.nix) — by
# handing makeRustPlatform a `cargo` that routes `cargo build` through cargo-wasix. So
# cargoBuildHook drives it normally: nothing skipped (no dontCargoBuild), nothing
# reimplemented (vendoring + arg handling are buildRustPackage's).
{
  lib,
  pkgsCross,
  wasixRustToolchain,
  cargo,
  cargoWasix,
}: let
  hostTriple = "x86_64-unknown-linux-gnu";
  rustLld = "${wasixRustToolchain}/lib/rustlib/${hostTriple}/bin/rust-lld";

  # The `cargo` buildRustPackage runs, routed: `cargo build …` goes through cargo-wasix,
  # everything else (metadata, etc.) to the real cargo.
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
in
  base
  // {
    buildRustPackage = args:
      base.buildRustPackage (
        finalAttrs: let
          # Accept both forms (attrset, or `finalAttrs:` function — what most nixpkgs
          # packages use, so prev.<pkg>.override works).
          a =
            if builtins.isFunction args
            then args finalAttrs
            else args;
        in
          {
            # wasm can't run tests / installChecks on the build host.
            doCheck = false;
            doInstallCheck = false;
            # cargo-auditable would re-link via the host rustc; unneeded for wasm.
            auditable = false;
          }
          // a
          // {
            # setEnv points CARGO_TARGET_<wasm>_LINKER at the wasi clang, which can't take
            # rustc's raw wasm-ld flags; override it with the toolchain's rust-lld (the
            # spec's native flavor). Flows through cargoBuildHook → the shim → cargo-wasix.
            cargoBuildFlags =
              ["--config" ''target.wasm32-wasmer-wasi.linker="${rustLld}"'']
              ++ (a.cargoBuildFlags or []);

            # Install each CLI cargo-wasix emitted (<name>.wasm; skip its .wasi/.rustc
            # intermediates).
            installPhase =
              a.installPhase or ''
                runHook preInstall
                mkdir -p "$out/bin"
                shopt -s nullglob
                for w in target/wasm32-wasmer-wasi/release/*.wasm; do
                  case "$w" in *.wasi.wasm | *.rustc.wasm) continue ;; esac
                  install -Dm644 "$w" "$out/bin/$(basename "$w")"
                done
                runHook postInstall
              '';

            passthru =
              (a.passthru or {})
              // {wasix = ((a.passthru or {}).wasix or {}) // {preferredProfile = "eh";};};

            meta = (a.meta or {}) // {platforms = (a.meta or {}).platforms or lib.platforms.all;};
          }
      );
  }
