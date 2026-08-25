# crabsay, a ferris-says clone in Rust. Not in nixpkgs, so built from source
# via the wasix rustPlatform, which installs the .wasm and sets the eh profile
# and meta.platforms like any other rust CLI here.
{
  exposePackage,
  packageSet,
  scope,
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
      passthru =
        {
          wasix.supportedProfiles = ["eh" "ehpic"];
          # upstream cuts no releases, so track its default branch
          updateScript = {
            command = packageSet.nix-update-script {extraArgs = ["--flake" "--version=branch"];};
            accepts = ["revision"];
            source = {
              kind = "github";
              owner = "Zaechus";
              repo = "crabsay";
            };
          };
          # 0-unstable-YYYY-MM-DD: the date is the whole version, so put it in the
          # patch. 0.0.x leaves room for a real 0.1.0 to sort above the snapshots.
          # Prefer 0.0.0-unstable.YYYY.M.D once wasmer resolves prerelease-only
          # packages (WASIX-TODO.md).
        }
        // lib.optionalAttrs (scope == "wasix") {
          wasinix.shipped = true;
          wasmer.version = v: let
            d = builtins.match ".*-unstable-([0-9]{4})-([0-9]{2})-([0-9]{2})" v;
          in
            assert lib.assertMsg (d != null) "crabsay: version ${v} is not <ver>-unstable-YYYY-MM-DD"; "0.0.${lib.concatStrings d}";
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
