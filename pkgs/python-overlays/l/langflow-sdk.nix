{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (
  packages.sameProfile.buildPythonPackage (finalAttrs: {
    pname = "langflow-sdk";
    version = "0.3.2";
    format = "wheel";

    src = packages.sameProfile.fetchPypi {
      pname = "langflow_sdk";
      inherit (finalAttrs) version;
      format = "wheel";
      dist = "py3";
      python = "py3";
      hash = "sha256-N22F5iy+J157WUHlqMlFByY1KFprSPUQKVtFCjWrzz0=";
    };

    pythonRelaxDeps = true;
    dependencies = with packages.sameProfile; [
      httpx
      pydantic
      pydantic-settings
      tomli
      typing-extensions
    ];
    pythonImportsCheck = ["langflow_sdk"];

    passthru.updateScript = pkgs.buildPackages.nix-update-script {extraArgs = ["--flake"];};
  })
)
