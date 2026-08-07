{
  stdenv,
  lib,
  bash,
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
  shellPath ? "${bash}/bin/bash",
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "anybuild";
  version = "0.26.5";

  src = fetchFromGitHub {
    owner = "wasmerio";
    repo = "anybuild";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Xai//mueLGjLLvt2drrgmxtfo3qTqo+B+3/TA5guHdI=";
  };

  cargoHash = "sha256-CqOF9SZoMhBE2lJAWBCLLczyOQiHU5tdGvAo2ajjQ0Y=";

  postPatch = ''
    substituteInPlace crates/anybuild/src/run/local.rs \
      --replace-fail '#!/bin/bash' '#!${shellPath}'
  '';

  # The e2e harness otherwise assumes a separate target/debug build exists.
  preCheck = ''
    export ANYBUILD_BIN="$PWD/target/${stdenv.hostPlatform.rust.rustcTarget}/release/anybuild"
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
})
