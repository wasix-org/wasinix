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
    # Vendored by fetchCargoVendor, which reads the in-source lockfile at build
    # time; `cargoLock.lockFile = "${src}/Cargo.lock"` would read it during eval
    # (import-from-derivation), forcing the fetch before any attr can be listed.
    cargoHash = "sha256-JBuSAfDv1MlZt2tXR6bh+4ZlzH6joFjD5JXH+ZuuD+A=";

    patches = [
      # The no-input passthrough runs clang without pinning the linker, so probes
      # like meson's `cc -Wl,--version` fail to find wasm-ld on PATH. TODO: upstream.
      ./wasixcc-pin-linker-in-passthrough.patch
      # Keep user `-Wl,` flags and file inputs in one ordered stream so
      # `--whole-archive lib.a --no-whole-archive` brackets reach wasm-ld intact.
      # Also folds in the `--undefined-version` discard. TODO: upstream, then drop.
      ./wasixcc-preserve-link-order.patch
      # Path::extension only sees the last component, so a versioned shared
      # library (libfoo.so.1.2.3, what cmake emits for a target with SOVERSION)
      # was partitioned as a source file: the driver then expected a compiled
      # <tmp>/libfoo.so.1.2.3.o that nothing produces and the link failed with
      # "cannot open". TODO: upstream, then drop.
      ./wasixcc-versioned-soname-inputs.patch
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
        {message = "check whether the vendored wasixcc-*.patch fixes landed upstream";}
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
