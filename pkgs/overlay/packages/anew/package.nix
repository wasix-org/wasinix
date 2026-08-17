{
  final,
  helpers,
  nix-update-script,
  ...
}:
helpers.wasmRename {wasmName = "anew";} (
  final.buildGoModule {
    pname = "anew";
    version = "0.2";
    src = final.fetchFromGitHub {
      owner = "tomnomnom";
      repo = "anew";
      tag = "v0.2";
      hash = "sha256-NQSs99/2GPOtXkO7k+ar16G4Ecu4CPGMd/CTwEhcyto=";
    };
    vendorHash = null;
    subPackages = ["."];

    passthru = {
      wasix.shipped = true;
      updateScript = nix-update-script {extraArgs = ["--flake"];};
    };

    meta = {
      description = "Tool for adding new lines to files while skipping duplicates";
      homepage = "https://github.com/tomnomnom/anew";
      mainProgram = "anew";
      license = final.lib.licenses.mit;
    };
  }
)
