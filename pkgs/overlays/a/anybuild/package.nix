{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.callPackage ({
  lib,
  stdenv,
  buildPackages,
  bash,
  rustPlatform,
  fetchFromGitHub,
  shellPath ? lib.getExe bash,
}: let
  inherit (buildPackages) nix-update-script;
in
  rustPlatform.buildRustPackage (finalAttrs: {
    pname = "anybuild";
    version = "0.28.0";

    src = fetchFromGitHub {
      owner = "wasmerio";
      repo = "anybuild";
      tag = "v${finalAttrs.version}";
      hash = "sha256-WYyr+Lis0rVs9bwNtzHtMtRx/4anM+O7TTmS4d3bIM4=";
    };

    cargoHash = "sha256-uMKjsztKNQ+qrR8RaBBLCMOsudKjLk0f0XN6wBYOsgw=";

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
      wasix.supportedProfiles = ["eh" "ehpic"];
      updateScript = {
        command = nix-update-script {extraArgs = ["--flake"];};
        attrPath = "packages.native.anybuild";
        accepts = ["release" "revision"];
        source = {
          kind = "github";
          owner = "wasmerio";
          repo = "anybuild";
        };
      };
      # The template tests pin PyPI from this source's examples/, so a bump has to
      # re-resolve them. The script no-ops unless the recorded version moved.
      wasinix.update.post = [
        (lib.getExe (buildPackages.writeShellApplication {
          name = "anybuild-update-mirror";
          runtimeInputs = with buildPackages; [git python3 uv];
          text = ''
            exec python3 "$(git rev-parse --show-toplevel)/pkgs/overlays/a/anybuild/update-mirror.py" "$@"
          '';
        }))
      ];
    };

    meta = {
      description = "Detect, build, and run projects";
      longDescription = "A command-line tool that detects project types, builds them with the appropriate toolchain, and runs the resulting programs.";
      homepage = "https://github.com/wasmerio/anybuild";
      changelog = "https://github.com/wasmerio/anybuild/releases/tag/v${finalAttrs.version}";
      license = lib.licenses.mit;
      mainProgram = "anybuild";
    };
  })) {})
