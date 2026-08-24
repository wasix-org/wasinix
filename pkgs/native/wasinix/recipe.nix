{
  bash,
  coreutils,
  gitMinimal,
  installShellFiles,
  lib,
  nix-eval-jobs,
  nixVersions,
  openssh,
  rustPlatform,
  symlinkJoin,
  wasinixCapabilityFlake ? null,
  writeShellApplication,
}: let
  commandAliases = ["build" "spot" "diff" "run" "remote" "ci"];
  source = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      ../../../schema/project.json
      ../../../tools/wasinix
    ];
  };
  unwrapped = rustPlatform.buildRustPackage {
    pname = "wasinix";
    version = "0.1.0";
    src = source;
    sourceRoot = "${source.name}/tools/wasinix";
    cargoLock.lockFile = ../../../tools/wasinix/Cargo.lock;
    doCheck = false;
    meta.mainProgram = "wasinix";
  };
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
