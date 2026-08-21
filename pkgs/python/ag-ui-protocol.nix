{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (
  packages.sameProfile.buildPythonPackage rec {
    pname = "ag-ui-protocol";
    version = "0.1.18";
    format = "wheel";

    src = packages.sameProfile.fetchPypi {
      pname = "ag_ui_protocol";
      inherit version format;
      dist = "py3";
      python = "py3";
      hash = "sha256-0VHA8KNBYGR/FXEWP3GFdG9DJrFaVtFWDeUIKnoOehI=";
    };

    dependencies = [packages.sameProfile.pydantic];
    pythonImportsCheck = ["ag_ui_protocol"];

    passthru.updateScript = pkgs.buildPackages.nix-update-script {extraArgs = ["--flake"];};
  }
)
