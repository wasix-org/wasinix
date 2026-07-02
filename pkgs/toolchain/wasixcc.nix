# wasixcc — the WASIX cc driver. The raw wasixccenv binary is built from source;
# bin/ holds one makeWrapper wrapper per tool name (wasixcc, wasix++, …), each
# exec'ing wasixccenv under that argv0 (it dispatches on the invoked name) with
# the toolchain locations from the shared env contract (env.nix) baked in.
#
# Update instructions:
# 1) Update `src.rev` and `src.hash` to the target wasix-org/wasixcc commit, and
#    `version` to that commit's Cargo.toml package.version.
# 2) The Cargo.lock ships in-source, so dependency changes vendor automatically.
{
  lib,
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  makeWrapper,
  wasixLlvm,
  binaryen,
  wasixSysroot,
}: let
  env = import ./env.nix {inherit lib;};

  # Mirrors the pinned rev's Cargo.toml package.version. A literal: reading it
  # via fromTOML(readFile "${src}/…") would be IFD, forcing the fetch at eval.
  version = "0.4.2";
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasixcc";
    rev = "f60fd7d03690fc778633b3616caee39015fb8404";
    hash = "sha256-opTdoRjWIsNDCce2XaUdmn9RwzpesqXusw5QHp5Q8FE=";
  };

  wasixccRaw = rustPlatform.buildRustPackage {
    pname = "wasixcc-raw";
    inherit version src;
    cargoLock.lockFile = "${src}/Cargo.lock";

    patches = [
      ./wasixcc-discard-undefined-version.patch
      # wasixcc's no-input passthrough runs clang without pinning the linker, so
      # clang-driven linker probes (meson's `cc -Wl,--version`) fail to find a bare
      # `wasm-ld` off PATH. Pin it. TODO: upstream to wasix-org/wasixcc.
      ./wasixcc-pin-linker-in-passthrough.patch
      # wasixcc only links the C++ runtime (-lc++/-lc++abi) into executables, not
      # shared libraries — so a C++ CPython extension's .so leaves its libc++ symbols
      # as unresolved dynamic imports that the C interpreter can't satisfy at load.
      # Link the C++ runtime into C++ shared libs too. TODO: upstream.
      ./wasixcc-link-cxx-runtime-into-shared-libs.patch
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
      install -Dm755 "${wasixccRaw}/libexec/wasixccenv" "$out/libexec/wasixccenv"
      for cmd in ${lib.escapeShellArgs tools}; do
        makeWrapper "$out/libexec/wasixccenv" "$out/bin/$cmd" \
          --argv0 "$cmd" \
          ${env.makeWrapperFlagsOf (env.locationEnv {inherit wasixLlvm binaryen wasixSysroot;})}
      done
      runHook postInstall
    '';

    meta = {
      description = "WASIX C/C++ compiler driver (clang/lld/binaryen orchestrator), wrapped with the from-source toolchain";
      homepage = "https://github.com/wasix-org/wasixcc";
      license = with lib.licenses; [mit asl20];
      # The wrapped toolchain (LLVM fork, sysroot) is only built for x86_64-linux.
      platforms = ["x86_64-linux"];
      mainProgram = "wasixcc";
    };
  }
