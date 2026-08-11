{
  lib,
  stdenv,
  bash,
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
  shellPath ? "${bash}/bin/bash",
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "anybuild";
  version = "0.27.0";

  src = fetchFromGitHub {
    owner = "wasmerio";
    repo = "anybuild";
    tag = "v${finalAttrs.version}";
    hash = "sha256-6+6Uj6fqjo5L2PQNn5ggGyqV2az2SAXk8gwGMegbB1k=";
  };

  cargoHash = "sha256-BiEVEJe5uEHbpyx2p/CREIdEwgJAwZykb6Pedu/47kE=";

  postPatch = ''
    substituteInPlace crates/anybuild/src/run/local.rs \
      --replace-fail '#!/bin/bash' '#!${shellPath}'
  '';

  # The test harness otherwise assumes a separate target/debug build exists.
  preCheck = ''
    export ANYBUILD_BIN="$PWD/target/${stdenv.hostPlatform.rust.rustcTarget}/release/anybuild"
  '';

  passthru.updateScript = {
    command = nix-update-script {extraArgs = ["--flake"];};
    attrPath = "nativePackages.anybuild";
  };

  meta = {
    description = "Detect, build, and run projects";
    homepage = "https://github.com/wasmerio/anybuild";
    license = lib.licenses.mit;
    mainProgram = "anybuild";
  };
})
