{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (
  packages.sameProfile.rustPlatform.buildRustPackage (finalAttrs: {
    pname = "wasix-sendmail";
    version = "0.1.10";

    src = packages.sameProfile.fetchFromGitHub {
      owner = "wasix-org";
      repo = "wasix-sendmail";
      tag = "v${finalAttrs.version}";
      hash = "sha256-2gdbeJgJ+CertmJp0r0K8InU7A8mEUmLm1IejMuUWps=";
    };

    cargoPatches = [./dependencies.patch];
    cargoHash = "sha256-bLGQmYdPMMaVPzpvotqiCxr4QTZ/U7cX9kmm2b6ncwQ=";

    passthru = {
      wasinix.shipped = true;
      wasmer = {
        owner = "sendmail";
        name = "sendmail";
      };
      updateScript = pkgs.nix-update-script {extraArgs = ["--flake"];};
    };

    meta = {
      description = "Sendmail-compatible email sender with multiple backends";
      homepage = "https://github.com/wasix-org/wasix-sendmail";
      license = packages.sameProfile.lib.licenses.agpl3Only;
      mainProgram = "sendmail";
    };
  })
)
