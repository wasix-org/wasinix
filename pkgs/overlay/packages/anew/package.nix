{
  final,
  helpers,
  nix-update-script,
  ...
}:
helpers.wasmRename {wasmName = "anew";} (
  final.buildGoModule (finalAttrs: {
    pname = "anew";
    version = "0.2";
    src = final.fetchFromGitHub {
      owner = "tomnomnom";
      repo = "anew";
      tag = "v${finalAttrs.version}";
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
      longDescription = "A command-line tool that appends lines to a file while ignoring lines that are already present.";
      homepage = "https://github.com/tomnomnom/anew";
      changelog = "https://github.com/tomnomnom/anew/tree/v${finalAttrs.version}";
      platforms = final.lib.platforms.all;
      mainProgram = "anew";
      license = final.lib.licenses.mit;
    };
  })
)
