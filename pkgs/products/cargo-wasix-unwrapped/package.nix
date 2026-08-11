# cargo-wasix, the cargo subcommand driving WASIX builds. The toolchain wraps
# this with the compiler env and the rustup linking it expects; the recipe lives
# here so a WASIX build of the subcommand is the same program as the native one.
{
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "cargo-wasix-unwrapped";
  version = "0.1.33";

  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "cargo-wasix";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Jd9Dr2P9lqPhlHo1VAU6QBLY4RIAuAuNC7RKUdJL/ZI=";
  };

  cargoHash = "sha256-0bQGbrYpqusf1yviMHihhtxyu2ACqiCHgmWtZbhsBn4=";

  # The integration suite creates empty CARGO_HOMEs then invokes cargo-wasix,
  # which downloads the WASIX target. Its download_toolchain unit test also
  # contacts GitHub. Keep the remaining offline library unit tests.
  cargoTestFlags = ["--lib"];
  checkFlags = ["--skip" "toolchain::tests::test_download_toolchain"];

  passthru.updateScript = nix-update-script {};
})
