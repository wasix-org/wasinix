# A hello-world sanity test for the from-source wasix Rust toolchain: build a tiny crate
# through the wasix `rustPlatform.buildRustPackage` — the real consumer path, the same
# machinery sd/crabsay use — and run the result under wasmer, asserting it prints.
#
# This is the Rust analogue of stdenv-test.nix / link-test.nix. Running under wasmer is
# the actual check: a Rust wasm whose shared memory came out non-growable exits 70 at std
# startup, which fails the run here — so this guards directly against the stable-channel
# regression (see WASIX-TODO "Rust", and [[wasix-rust-nightly-channel]] in memory).
{
  lib,
  runCommand,
  writeText,
  rustPlatform,
  wasmer,
}: let
  cargoToml = writeText "Cargo.toml" ''
    [package]
    name = "wasix-rust-test"
    version = "0.0.0"
    edition = "2021"

    [[bin]]
    name = "hello"
    path = "src/main.rs"
  '';
  # No dependencies, so the lock is just the crate itself (no vendoring needed).
  cargoLock = writeText "Cargo.lock" ''
    version = 3

    [[package]]
    name = "wasix-rust-test"
    version = "0.0.0"
  '';
  mainRs = writeText "main.rs" ''
    fn main() {
        // A heap allocation: forces the startup path that traps on a non-growable
        // memory, so a stable-channel regression fails the run rather than slipping by.
        let msg = String::from("hello from wasix rust");
        println!("{msg}");
    }
  '';
  src = runCommand "wasix-rust-test-src" {} ''
    mkdir -p "$out/src"
    cp ${cargoToml} "$out/Cargo.toml"
    cp ${cargoLock} "$out/Cargo.lock"
    cp ${mainRs} "$out/src/main.rs"
  '';
in
  rustPlatform.buildRustPackage {
    pname = "wasix-rust-test";
    version = "0.0.0";
    inherit src;
    cargoLock.lockFile = "${src}/Cargo.lock";

    # Build hello.wasm, then run it under wasmer as the check (build phase is the stock
    # cargo build for wasm32-wasmer-wasi; only the install/run is bespoke).
    installPhase = ''
      runHook preInstall
      wasm=target/wasm32-wasmer-wasi/release/hello.wasm
      magic="$(od -An -tx1 -N4 "$wasm" | tr -d ' \n')"
      [ "$magic" = "0061736d" ] || { echo "not a wasm module (magic=$magic)"; exit 1; }
      install -Dm644 "$wasm" "$out/bin/hello.wasm"

      export HOME="$TMPDIR" WASMER_DIR="$TMPDIR/.wasmer"
      got="$(${wasmer}/bin/wasmer run "$out/bin/hello.wasm")"
      echo "wasmer output: [$got]"
      [ "$got" = "hello from wasix rust" ] || {
        echo "FAIL: unexpected output (Rust wasm didn't run correctly)"
        exit 1
      }
      echo "rust hello-world ran OK under wasmer"
      runHook postInstall
    '';

    meta.description = "wasix Rust toolchain hello-world build + run-under-wasmer sanity test";
  }
