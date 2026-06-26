{
  lib,
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  cargoWasix,
}: let
  src = fetchFromGitHub {
    owner = "Zaechus";
    repo = "crabsay";
    rev = "2ed8af9b16dc1e8d04851b62314e878536112ca9";
    hash = "sha256-ptHjotWwpEJ4xz12pSTHxPh7+6EuPKM6ZnXT6WurVq8=";
  };
in
  stdenvNoCC.mkDerivation {
    pname = "crabsay";
    version = "0.1.1";

    inherit src;

    cargoDeps = rustPlatform.importCargoLock {
      lockFile = "${src}/Cargo.lock";
    };

    nativeBuildInputs = [
      cargoWasix
      rustPlatform.cargoSetupHook
    ];

    buildPhase = ''
      runHook preBuild
      # cargoSetupHook owns CARGO_HOME (points cargo at the vendored deps); we just
      # need a writable HOME/RUSTUP_HOME for cargo-wasix's own state.
      export HOME="$PWD/.home"
      export RUSTUP_HOME="$HOME/.rustup"
      mkdir -p "$HOME" "$RUSTUP_HOME"
      cargo-wasix wasix build --release --offline
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      cp target/wasm32-wasmer-wasi/release/crabsay.wasm "$out/bin/crabsay.wasm"
      runHook postInstall
    '';
  }
