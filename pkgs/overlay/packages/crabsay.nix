# crabsay, a ferris-says clone in Rust. Not in nixpkgs, so built from source
# via the wasix rustPlatform, which installs the .wasm and sets the eh profile
# and meta.platforms like any other rust CLI here.
{final, ...}:
final.rustPlatform.buildRustPackage {
  pname = "crabsay";
  version = "0-unstable-2023-02-22";
  src = final.fetchFromGitHub {
    owner = "Zaechus";
    repo = "crabsay";
    rev = "2ed8af9b16dc1e8d04851b62314e878536112ca9";
    hash = "sha256-ptHjotWwpEJ4xz12pSTHxPh7+6EuPKM6ZnXT6WurVq8=";
  };
  cargoHash = "sha256-ejCXTplGKAtJjkOO6yAkR/TDiXKqiXZseXkcwrx0e2c=";
  passthru.wasix.shipped = true;
  meta = {
    description = "ferris-says clone, built to WASIX";
    homepage = "https://github.com/Zaechus/crabsay";
    mainProgram = "crabsay";
  };
}
