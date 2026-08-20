# Hello-world test for the wasix Rust toolchain: build a tiny crate through the
# wasix `rustPlatform.buildRustPackage` (the same path real packages use) and run
# it under wasmer, asserting it prints. Running is the real check: a Rust wasm
# with non-growable shared memory exits 70 at std startup, so this guards against
# the stable-channel regression (see the release-channel note in rust/toolchain.nix).
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
  # Held as a string and passed as lockFileContents; reading it back out of the
  # built `src` would be import-from-derivation.
  cargoLockText = ''
    version = 3

    [[package]]
    name = "wasix-rust-test"
    version = "0.0.0"
  '';
  cargoLockFile = writeText "Cargo.lock" cargoLockText;
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
    cp ${cargoLockFile} "$out/Cargo.lock"
    cp ${mainRs} "$out/src/main.rs"
  '';
in
  rustPlatform.buildRustPackage {
    pname = "wasix-rust-test";
    version = "0.0.0";
    inherit src;
    cargoLock.lockFileContents = cargoLockText;

    # Stock cargo build for wasm32-wasmer-wasi; the install phase runs the wasm
    # under wasmer as the check.
    installPhase = ''
      runHook preInstall
      wasm=target/wasm32-wasmer-wasi/release/hello.wasm
      magic="$(od -An -tx1 -N4 "$wasm" | tr -d ' \n')"
      [ "$magic" = "0061736d" ] || { echo "not a wasm module (magic=$magic)"; exit 1; }
      install -Dm644 "$wasm" "$out/bin/hello.wasm"

      export HOME="$TMPDIR" WASMER_DIR="$TMPDIR/.wasmer"
      got="$(${lib.getExe wasmer} run --quiet "$out/bin/hello.wasm")"
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
