# wasixcc, the WASIX cc driver. The wasixccenv binary dispatches on argv0; bin/
# holds one makeWrapper wrapper per tool name, with the toolchain locations from
# env.nix baked in.
{
  lib,
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  makeWrapper,
  nix-update-script,
  wasixLlvm,
  binaryen,
  wasixSysroot,
}: let
  env = import ./env.nix {inherit lib;};

  version = "0.4.4";
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasixcc";
    tag = "v${version}";
    hash = "sha256-8ifkYmPoKLlTeZHww+wMyFRYWkK3hOKx3vOlEP+4bYo=";
  };

  wasixccUnwrapped = rustPlatform.buildRustPackage {
    pname = "wasixcc-unwrapped";
    inherit version src;

    # Upstream's lock + .cargo/config.toml resolve through the WASIX overlay
    # registry (+wasix.N versions 403 on crates.io, and the in-source config
    # outranks the vendored source replacement); this host build needs neither.
    cargoLock.lockFile = ./wasixcc.Cargo.lock;
    postPatch = ''
      cp ${./wasixcc.Cargo.lock} Cargo.lock
      rm .cargo/config.toml
    '';

    doCheck = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/libexec"
      cp "$(find target -type f -path '*/release/wasixccenv' | head -n 1)" "$out/libexec/wasixccenv"
      runHook postInstall
    '';
  };

  # wasixccenv dispatches on its invoked name; expose it under every tool name.
  tools = ["wasixcc" "wasix++" "wasixcc++" "wasixar" "wasixnm" "wasixranlib" "wasixld" "wasixccenv"];
in
  stdenvNoCC.mkDerivation {
    pname = "wasixcc";
    inherit version;
    dontUnpack = true;

    nativeBuildInputs = [makeWrapper];

    installPhase = ''
      runHook preInstall
      install -Dm755 "${wasixccUnwrapped}/libexec/wasixccenv" "$out/libexec/wasixccenv"
      for cmd in ${lib.escapeShellArgs tools}; do
        makeWrapper "$out/libexec/wasixccenv" "$out/bin/$cmd" \
          --argv0 "$cmd" \
          ${env.makeWrapperFlagsOf (env.locationEnv {inherit wasixLlvm binaryen wasixSysroot;})}
      done
      runHook postInstall
    '';

    passthru = {
      unwrapped = wasixccUnwrapped;
      # nix-update needs version + src on the drv it evals: the wrapper has
      # neither, so point it at the unwrapped package
      updateScript = {
        command = nix-update-script {extraArgs = ["--flake"];};
        attrPath = "toolchain.wasixcc.unwrapped";
      };
      wasix.updateNotes = [
        {message = "regenerate wasixcc.Cargo.lock: delete upstream's Cargo.lock and .cargo/config.toml, then `cargo generate-lockfile`; drop the override once upstream keeps the WASIX registry out of the default build";}
      ];
    };

    meta = {
      description = "WASIX C/C++ compiler driver (clang/lld/binaryen orchestrator), wrapped with the from-source toolchain";
      homepage = "https://github.com/wasix-org/wasixcc";
      license = with lib.licenses; [mit asl20];
      # The wrapped toolchain (LLVM fork, sysroot) is only built for x86_64-linux.
      platforms = ["x86_64-linux"];
      mainProgram = "wasixcc";
    };
  }
