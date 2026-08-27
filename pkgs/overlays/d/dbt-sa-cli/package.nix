# dbt's Fusion engine, the binary PyPI publishes as both dbt-core 2.x and
# dbt-core-experimental-parser (release-v2.yml packs one build under two
# distribution names). Python dbt-core 1.12 requires the parser distribution, so
# the wheel needs this.
{
  exposePackage,
  packageSet,
}:
exposePackage (
  packageSet.rustPlatform.buildRustPackage (finalAttrs: {
    pname = "dbt-sa-cli";
    version = "2.0.0-alpha.5";

    src = packageSet.fetchFromGitHub {
      owner = "dbt-labs";
      repo = "dbt-core";
      tag = "v${finalAttrs.version}";
      hash = "sha256-ewetmvf31eVLFw5v7N/nGYxkO5TrA5eRxt2vi8puVAM=";
    };

    cargoHash = "sha256-UvOdffMzoUHL6Etyw4CX8PxrA7ioIKf0gX5n9vH3oVw=";

    cargoBuildFlags = ["-p" "dbt-sa-cli"];

    # dbt-state's build script generates prost bindings, so protoc runs on the
    # build host; prost-build looks it up by env before PATH.
    nativeBuildInputs = [packageSet.buildPackages.protobuf];
    env.PROTOC = packageSet.lib.getExe' packageSet.buildPackages.protobuf "protoc";

    doCheck = false;

    # 113 MB of wasm from an 819-crate workspace, and the wheel takes it through
    # packages.wasix.preferred, so one profile is the build anyone consumes.
    passthru.wasix = {
      supportedProfiles = ["eh" "ehpic"];
      preferredProfile = "eh";
    };

    meta = {
      description = "dbt Fusion engine CLI";
      longDescription = "The dbt Fusion command-line engine for parsing, compiling, and running dbt projects.";
      homepage = "https://github.com/dbt-labs/dbt-core";
      changelog = "https://github.com/dbt-labs/dbt-core/releases/tag/v${finalAttrs.version}";
      license = packageSet.lib.licenses.asl20;
      mainProgram = "dbt-sa-cli";
    };
  })
)
