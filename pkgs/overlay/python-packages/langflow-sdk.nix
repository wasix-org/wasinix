{
  nix-update-script,
  pyfinal,
  ...
}:
pyfinal.buildPythonPackage (finalAttrs: {
  pname = "langflow-sdk";
  version = "0.3.2";
  format = "wheel";

  src = pyfinal.fetchPypi {
    pname = "langflow_sdk";
    inherit (finalAttrs) version format;
    dist = "py3";
    python = "py3";
    hash = "sha256-N22F5iy+J157WUHlqMlFByY1KFprSPUQKVtFCjWrzz0=";
  };

  pythonRelaxDeps = true;
  dependencies = with pyfinal; [
    httpx
    pydantic
    pydantic-settings
    tomli
    typing-extensions
  ];
  pythonImportsCheck = ["langflow_sdk"];

  passthru.updateScript = nix-update-script {extraArgs = ["--flake"];};
})
