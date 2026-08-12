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

  patches = [
    # python_index_url / ANYBUILD_PYTHON_INDEX_URL: the cross-wheel steps
    # hardcode --index-url=https://pypi.org/simple, and --emit-index-url bakes
    # it into cross-requirements.txt, so nothing can resolve off pypi.org.
    ./python-index-url.patch
    # ANYBUILD_WASMER_PACKAGE_<DEP>: the runtime package a toolchain dependency
    # maps to is a fixed table entry, so a build cannot target another build of
    # the same runtime.
    ./wasmer-package-override.patch
  ];

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
