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
      # Relocatable links must bypass executable setup. Meson prelinking exposed
      # the driver's attempt to add crt and resolve main for `-r`.
      ./wasixcc-relocatable-link-passthrough.patch
      ./wasixcc-rlib-linker-input.patch
      ./wasixcc-nodefaultlibs.patch
      ./wasixcc-nostartfiles.patch
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
      wasix.updateNotes = [
        {message = "check whether wasixcc-relocatable-link-passthrough.patch landed upstream";}
        {message = "regenerate wasixcc.Cargo.lock: delete upstream's Cargo.lock and .cargo/config.toml, then `cargo generate-lockfile`; drop the override once upstream keeps the WASIX registry out of the default build";}
        {message = "drop wasixcc-rlib-linker-input.patch once wasixcc recognizes Rust .rlib archives as linker inputs";}
        {message = "drop wasixcc-nodefaultlibs.patch once wasixcc honors -nodefaultlibs without forwarding it to wasm-ld";}
        {message = "drop wasixcc-nostartfiles.patch once wasixcc honors -nostartfiles without forwarding it to wasm-ld";}
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
