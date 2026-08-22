{
  awscli2,
  bash,
  coreutils,
  git,
  gitMinimal,
  installShellFiles,
  lib,
  nix-eval-jobs,
  nixVersions,
  openssh,
  python3,
  rclone,
  rustPlatform,
  symlinkJoin,
  wasmer,
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
    doCheck = true;
    nativeCheckInputs = [gitMinimal nixVersions.latest];
    meta.mainProgram = "wasinix";
  };
  launcher = writeShellApplication {
    name = "wasinix";
    inheritPath = false;
    runtimeInputs = [
      awscli2
      bash
      coreutils
      git
      nix-eval-jobs
      nixVersions.latest
      openssh
      python3
      rclone
      wasmer
    ];
    text = ''
      PATH="''${0%/*}:$PATH" exec ${lib.getExe unwrapped} "$@"
    '';
  };
in
  symlinkJoin {
    name = "wasinix";
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
      wasinix.checks.behavior = true;
    };
    meta.mainProgram = "wasinix";
  }
