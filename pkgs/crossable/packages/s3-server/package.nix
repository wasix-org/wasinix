{
  lib,
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "s3-server";
  version = "0.1.22";
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "s3-server";
    tag = finalAttrs.version;
    hash = "sha256-SjcTkqfuEAXpJzFhlQaFfIhBQ7RZFo8uIK8S6ph5zi0=";
  };

  # The CLI (structopt/dotenv/tracing-subscriber) is behind the binary feature.
  buildFeatures = ["binary"];
  cargoHash = "sha256-iq6FnobEju7DIHacvoFPTTJDhCKMY3R4NE/QQKWiW9I=";

  passthru.updateScript = nix-update-script {
    extraArgs = ["--flake" "--version-regex" "^([0-9.]+)$"];
  };

  meta = {
    description = "Generic S3 server";
    homepage = "https://github.com/wasix-org/s3-server";
    license = lib.licenses.mit;
    mainProgram = "s3-server";
  };
})
