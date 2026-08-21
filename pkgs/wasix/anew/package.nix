{
  exposePackage,
  packages,
  pkgs,
  wasmRename,
}:
exposePackage (
  wasmRename {wasmName = "anew";} (
    packages.sameProfile.buildGoModule {
      pname = "anew";
      version = "0.2";
      src = packages.sameProfile.fetchFromGitHub {
        owner = "tomnomnom";
        repo = "anew";
        tag = "v0.2";
        hash = "sha256-NQSs99/2GPOtXkO7k+ar16G4Ecu4CPGMd/CTwEhcyto=";
      };
      vendorHash = null;
      subPackages = ["."];

      passthru = {
        wasinix.shipped = true;
        updateScript = pkgs.nix-update-script {extraArgs = ["--flake"];};
      };

      meta = {
        description = "Tool for adding new lines to files while skipping duplicates";
        homepage = "https://github.com/tomnomnom/anew";
        mainProgram = "anew";
        license = packages.sameProfile.lib.licenses.mit;
      };
    }
  )
)
