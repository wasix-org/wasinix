# cargo-wasix, the cargo subcommand driving WASIX builds. The toolchain wraps
# this with the compiler env and the rustup linking it expects; the package lives
# here so a WASIX build of the subcommand is the same program as the native one.
{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.callPackage ({
    lib,
    rustPlatform,
    fetchFromGitHub,
  }:
    rustPlatform.buildRustPackage (finalAttrs: {
      pname = "cargo-wasix";
      version = "0.1.33";

      src = fetchFromGitHub {
        owner = "wasix-org";
        repo = "cargo-wasix";
        tag = "v${finalAttrs.version}";
        hash = "sha256-Jd9Dr2P9lqPhlHo1VAU6QBLY4RIAuAuNC7RKUdJL/ZI=";
      };

      cargoHash = "sha256-0bQGbrYpqusf1yviMHihhtxyu2ACqiCHgmWtZbhsBn4=";

      # cargo-wasix's own RUSTFLAGS write is skipped whenever a package sets
      # RUSTFLAGS, so the wasm feature baseline lives in the rust target spec.
      patches = [./cargo-wasix-target-features.patch];

      # The integration suite creates empty CARGO_HOMEs then invokes cargo-wasix,
      # which downloads the WASIX target. Its download_toolchain unit test also
      # contacts GitHub. Keep the remaining offline library unit tests.
      cargoTestFlags = ["--lib"];
      checkFlags = ["--skip" "toolchain::tests::test_download_toolchain"];

      passthru.wasix.supportedProfiles = [];

      meta = {
        description = "Cargo subcommand for building Rust projects for WASIX";
        longDescription = "A Cargo subcommand that builds Rust projects for WASIX using the repository's compiler and runtime toolchain.";
        homepage = "https://github.com/wasix-org/cargo-wasix";
        changelog = "https://github.com/wasix-org/cargo-wasix/releases/tag/v${finalAttrs.version}";
        license = with lib.licenses; [mit asl20];
        mainProgram = "cargo-wasix";
      };
    })) {})
