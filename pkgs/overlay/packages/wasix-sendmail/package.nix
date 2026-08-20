{
  final,
  nix-update-script,
  ...
}:
final.rustPlatform.buildRustPackage (finalAttrs: {
  pname = "wasix-sendmail";
  version = "0.1.10";

  src = final.fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasix-sendmail";
    tag = "v${finalAttrs.version}";
    hash = "sha256-2gdbeJgJ+CertmJp0r0K8InU7A8mEUmLm1IejMuUWps=";
  };

  cargoPatches = [./dependencies.patch];
  cargoHash = "sha256-bLGQmYdPMMaVPzpvotqiCxr4QTZ/U7cX9kmm2b6ncwQ=";

  passthru = {
    wasix.shipped = true;
    wasmer = {
      owner = "sendmail";
      name = "sendmail";
    };
    updateScript = {
      command = nix-update-script {extraArgs = ["--flake"];};
      accepts = ["release" "revision"];
      source = {
        kind = "github";
        owner = "wasix-org";
        repo = "wasix-sendmail";
      };
    };
  };

  meta = {
    description = "Sendmail-compatible email sender with multiple backends";
    longDescription = "A sendmail-compatible command-line email sender with configurable delivery backends.";
    homepage = "https://github.com/wasix-org/wasix-sendmail";
    changelog = "https://github.com/wasix-org/wasix-sendmail/releases/tag/v${finalAttrs.version}";
    license = final.lib.licenses.agpl3Only;
    mainProgram = "sendmail";
  };
})
