{
  bash,
  coreutils,
  gitMinimal,
  installShellFiles,
  lib,
  nix-eval-jobs,
  nixVersions,
  openssh,
  symlinkJoin,
  wasinixCraneLib,
  wasinixCapabilityFlake ? null,
  writeShellApplication,
}: let
  commandAliases = ["build" "spot" "diff" "run" "remote" "update" "ci"];
  root = ../../../..;
  crateRoot = ../../../../tools/wasinix;
  productionSource = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      ../../../../schema/project.json
      ../../../../tools/wasinix/Cargo.lock
      ../../../../tools/wasinix/Cargo.toml
      ../../../../tools/wasinix/cargo-registry-wire
      (lib.fileset.difference ../../../../tools/wasinix/src ../../../../tools/wasinix/src/tests)
    ];
  };
  cargoArgs = {
    pname = "wasinix";
    version = "0.1.0";
    src = productionSource;
    cargoToml = crateRoot + /Cargo.toml;
    cargoLock = crateRoot + /Cargo.lock;
    strictDeps = true;
    postUnpack = ''
      cd "$sourceRoot/tools/wasinix"
      sourceRoot="."
    '';
  };
  cargoArtifacts = wasinixCraneLib.buildDepsOnly cargoArgs;
  helperFiles =
    lib.concatLists
    (builtins.attrValues (fromTOML (builtins.readFile ../../../helper-boundaries.toml)));
  testSource = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions (
      [
        ../../../../.github
        ../../../../flake.nix
        ../../../project/apps.nix
        ../../../project/repository.nix
        ../../../../schema/project.json
        ../../../helper-boundaries.toml
        ../../../../tools/wasinix
      ]
      ++ map (path: root + "/${path}") helperFiles
    );
  };
  unit = wasinixCraneLib.cargoTest (cargoArgs
    // {
      src = testSource;
      inherit cargoArtifacts;
      nativeCheckInputs = [gitMinimal nixVersions.latest];
    });
  unwrapped = wasinixCraneLib.buildPackage (cargoArgs
    // {
      inherit cargoArtifacts;
      doCheck = false;
      meta.mainProgram = "wasinix";
      passthru = {
        inherit cargoArtifacts unit;
      };
    });
  coreInputs = [
    bash
    coreutils
    gitMinimal
    nix-eval-jobs
    nixVersions.latest
    openssh
  ];
  mkWasinix = {
    name,
    runtimeInputs,
    capabilitiesOnPath,
  }: let
    launcher = writeShellApplication {
      name = "wasinix";
      inheritPath = false;
      inherit runtimeInputs;
      text = ''
        ${lib.optionalString (wasinixCapabilityFlake != null) "export WASINIX_CAPABILITY_FLAKE=${wasinixCapabilityFlake}"}
        export WASINIX_LAUNCHER="''${0%/bin/wasinix}"
        ${lib.optionalString capabilitiesOnPath "export WASINIX_CAPABILITIES_ON_PATH=1"}
        PATH="''${0%/*}:$PATH" exec ${lib.getExe unwrapped} "$@"
      '';
    };
  in
    symlinkJoin {
      inherit name;
      paths = [launcher];
      nativeBuildInputs = [installShellFiles];
      postBuild = ''
        installShellCompletion --cmd wasinix \
          --bash <(${lib.getExe unwrapped} completions bash) \
          --fish <(${lib.getExe unwrapped} completions fish) \
          --zsh <(${lib.getExe unwrapped} completions zsh)
      '';
      passthru = {
        inherit commandAliases unwrapped;
        withCapabilities = capabilities:
          mkWasinix {
            name = "wasinix";
            runtimeInputs = coreInputs ++ builtins.attrValues capabilities;
            capabilitiesOnPath = true;
          };
        wasinix.checks.behavior = true;
      };
      meta.mainProgram = "wasinix";
    };
in
  mkWasinix {
    name = "wasinix-core";
    runtimeInputs = coreInputs;
    capabilitiesOnPath = false;
  }
