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

  version = "0.4.5";
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasixcc";
    tag = "v${version}";
    hash = "sha256-dCBNXceJO9Wx91o7+g/iVzHiCeanC71NPk0PUsf4xN0=";
  };

  wasixccUnwrapped = rustPlatform.buildRustPackage {
    pname = "wasixcc-unwrapped";
    inherit version src;

    cargoHash = "sha256-6f0LnlsAKK/VywTFfjPIMBmG+Ht1q2ItRSvmKkd8qpU=";

    # A shared module gets no C++ runtime injected (that block is executable-only),
    # so a build system passing the GNU name -lstdc++ fails to link. -fopenmp is a
    # driver flag that never reaches wasm-ld, so the omp symbols go unresolved
    # unless the driver names libomp itself, as clang's own does.
    patches = [
      ./wasixcc-map-libstdcxx-to-libcxx.patch
      ./wasixcc-openmp-link.patch
    ];

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
