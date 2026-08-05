{
  lib,
  bash,
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
}:
rustPlatform.buildRustPackage rec {
  pname = "anybuild";
  version = "0.26.4";

  src = fetchFromGitHub {
    owner = "wasmerio";
    repo = "anybuild";
    tag = "v${version}";
    hash = "sha256-M6AP8QgIuoly9Gznw2JOAGEdKTY0+mJciYhA3JKicfk=";
  };

  cargoHash = "sha256-K9EkxIsTXOmqVnfv/ZQb97uXpO2100RKLQEyf5PjsAw=";

  postPatch = ''
    substituteInPlace crates/anybuild/src/run/local.rs \
      --replace-fail '#!/bin/bash' '#!${bash}/bin/bash'
  '';

  # The e2e harness otherwise assumes a separate target/debug build exists.
  preCheck = ''
    export ANYBUILD_BIN="$(find target -type f -path '*/release/anybuild' | head -n 1)"
  '';

  passthru.updateScript = {
    command = nix-update-script {extraArgs = ["--flake"];};
    attrPath = "toolchain.anybuild";
  };

  meta = {
    description = "Detect, build, and run projects";
    homepage = "https://github.com/wasmerio/anybuild";
    license = lib.licenses.mit;
    mainProgram = "anybuild";
  };
}
