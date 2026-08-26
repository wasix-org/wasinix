{
  exposePackage,
  packageSet,
}:
exposePackage (
  let
    inherit (packageSet) lib;
  in
    packageSet.rustPlatform.buildRustPackage {
      pname = "crabsay";
      version = "0-unstable-2023-02-22";
      src = packageSet.fetchFromGitHub {
        owner = "Zaechus";
        repo = "crabsay";
        rev = "2ed8af9b16dc1e8d04851b62314e878536112ca9";
        hash = "sha256-ptHjotWwpEJ4xz12pSTHxPh7+6EuPKM6ZnXT6WurVq8=";
      };
      cargoHash = "sha256-ejCXTplGKAtJjkOO6yAkR/TDiXKqiXZseXkcwrx0e2c=";
      passthru = {
        wasix.supportedProfiles = ["eh" "ehpic"];
        updateScript = {
          command = packageSet.nix-update-script {extraArgs = ["--flake" "--version=branch"];};
          accepts = ["revision"];
          source = {
            kind = "github";
            owner = "Zaechus";
            repo = "crabsay";
          };
        };
      };
      meta = {
        description = "ferris-says clone";
        longDescription = "A small Rust command-line program that renders messages as an ASCII crab.";
        homepage = "https://github.com/Zaechus/crabsay";
        license = with lib.licenses; [mit asl20];
        mainProgram = "crabsay";
      };
    }
)
