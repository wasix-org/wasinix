{
  nix-update-script,
  pyfinal,
  ...
}:
pyfinal.buildPythonPackage (finalAttrs: {
  pname = "ag-ui-protocol";
  version = "0.1.18";
  format = "wheel";

  src = pyfinal.fetchPypi {
    pname = "ag_ui_protocol";
    inherit (finalAttrs) version;
    format = "wheel";
    dist = "py3";
    python = "py3";
    hash = "sha256-0VHA8KNBYGR/FXEWP3GFdG9DJrFaVtFWDeUIKnoOehI=";
  };

  dependencies = [pyfinal.pydantic];
  pythonImportsCheck = ["ag_ui_protocol"];

  passthru.updateScript = nix-update-script {extraArgs = ["--flake"];};
})
