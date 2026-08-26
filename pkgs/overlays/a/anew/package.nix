{
  exposePackage,
  packageSet,
}:
exposePackage (
  packageSet.buildGoModule (finalAttrs: {
    pname = "anew";
    version = "0.2";
    src = packageSet.fetchFromGitHub {
      owner = "tomnomnom";
      repo = "anew";
      tag = "v${finalAttrs.version}";
      hash = "sha256-NQSs99/2GPOtXkO7k+ar16G4Ecu4CPGMd/CTwEhcyto=";
    };
    vendorHash = null;
    subPackages = ["."];

    passthru.updateScript = packageSet.nix-update-script {extraArgs = ["--flake"];};

    meta = {
      description = "Tool for adding new lines to files while skipping duplicates";
      longDescription = "A command-line tool that appends lines to a file while ignoring lines that are already present.";
      homepage = "https://github.com/tomnomnom/anew";
      changelog = "https://github.com/tomnomnom/anew/tree/v${finalAttrs.version}";
      platforms = packageSet.lib.platforms.all;
      mainProgram = "anew";
      license = packageSet.lib.licenses.mit;
    };
  })
)
