# crabsay — a plain Rust package. The only thing odd about it is that it's Rust:
# it builds via the overlay's rustPlatform (cross-targeting wasm32-wasmer-wasi with
# the from-source toolchain), the same way the C packages build via the wasixcc
# stdenv. No wasix specifics here beyond installing the .wasm by hand.
{final, ...}: let
  inherit (final) lib rustPlatform fetchFromGitHub;
  src = fetchFromGitHub {
    owner = "Zaechus";
    repo = "crabsay";
    rev = "2ed8af9b16dc1e8d04851b62314e878536112ca9";
    hash = "sha256-ptHjotWwpEJ4xz12pSTHxPh7+6EuPKM6ZnXT6WurVq8=";
  };
in
  rustPlatform.buildRustPackage {
    pname = "crabsay";
    version = "0.1.1";
    inherit src;

    cargoHash = "sha256-ejCXTplGKAtJjkOO6yAkR/TDiXKqiXZseXkcwrx0e2c=";

    # Rust only targets the eh variant, so ship crabsay from there (the overlay marks
    # it broken in the other profiles). preferredProfile is read without building, so
    # this resolves preferredPackages.crabsay -> the eh build.
    passthru.wasix.preferredProfile = "eh";

    # The bin artifact is crabsay.wasm, which the default install hook (expecting a
    # bare executable) doesn't pick up.
    installPhase = ''
      runHook preInstall
      install -Dm644 target/wasm32-wasmer-wasi/release/crabsay.wasm "$out/bin/crabsay.wasm"
      runHook postInstall
    '';

    meta = {
      description = "ferris-says clone, built to WASIX";
      homepage = "https://github.com/Zaechus/crabsay";
      mainProgram = "crabsay";
      platforms = lib.platforms.all;
    };
  }
