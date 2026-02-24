{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  cargoWasix,
}:
stdenvNoCC.mkDerivation rec {
  pname = "crabsay";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "nevzheng";
    repo = "crabsay";
    rev = "master";
    hash = "sha256-5DVY/eoP/WhIYpIY8vvSQC4gFTI3N2kQb4Lkn0bbfZ8=";
  };

  nativeBuildInputs = [ cargoWasix ];

  buildPhase = ''
    runHook preBuild
    export HOME="$PWD/.home"
    export CARGO_HOME="$HOME/.cargo"
    export RUSTUP_HOME="$HOME/.rustup"
    mkdir -p "$HOME" "$CARGO_HOME" "$RUSTUP_HOME"
    cargo-wasix wasix build --release
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp target/wasm32-wasmer-wasi/release/crabsay.wasm "$out/bin/crabsay.wasm"
    runHook postInstall
  '';
}
