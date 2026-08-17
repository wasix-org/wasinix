{
  lib,
  stdenv,
  buildPackages,
  bash,
  rustPlatform,
  fetchFromGitHub,
  nix-update-script,
  shellPath ? "${bash}/bin/bash",
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "anybuild";
  version = "0.27.2";

  src = fetchFromGitHub {
    owner = "wasmerio";
    repo = "anybuild";
    tag = "v${finalAttrs.version}";
    hash = "sha256-wQJwHk3aV989/5hNLkt2eQW9c3tU3bLePJg7MHzgv3g=";
  };

  cargoHash = "sha256-jKOffOlvGb4b8mHJnb9Xas8lfYQZZ/my0Rc/FRAbd0c=";

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

  passthru = {
    updateScript = {
      command = nix-update-script {extraArgs = ["--flake"];};
      attrPath = "nativePackages.anybuild";
      accepts = ["release" "revision"];
      source = {
        kind = "github";
        owner = "wasmerio";
        repo = "anybuild";
      };
    };
    # The template tests pin PyPI from this source's examples/, so a bump has to
    # re-resolve them. The script no-ops unless the recorded version moved.
    wasix.retentionHook = [
      "${buildPackages.writeShellApplication {
        name = "anybuild-update-mirror";
        runtimeInputs = with buildPackages; [git python3 uv];
        text = ''
          exec python3 "$(git rev-parse --show-toplevel)/pkgs/products/anybuild/update-mirror.py" "$@"
        '';
      }}/bin/anybuild-update-mirror"
    ];
  };

  meta = {
    description = "Detect, build, and run projects";
    homepage = "https://github.com/wasmerio/anybuild";
    license = lib.licenses.mit;
    mainProgram = "anybuild";
  };
})
