{
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  bash,
  wasixLlvm,
  binaryen,
  wasixSysroot,
  stdenv,
}:
let
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "wasixcc";
    rev = "7a4a6f72449e69ff1ebcc92efaf69c0dbbf1b00d";
    hash = "sha256-ZQIwzkVMY4YL7+9UcmSNy76+tjwf6Wdidp9Rr4i0ZSo=";
  };

  cargoToml = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
  version = cargoToml.package.version;

  supported = stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64;

  wasixccRaw = rustPlatform.buildRustPackage {
    pname = "wasixcc-raw";
    inherit version src;
    cargoLock.lockFile = "${src}/Cargo.lock";

    doCheck = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/libexec"
      cp "$(find target -type f -path '*/release/wasixccenv' | head -n 1)" "$out/libexec/wasixccenv"
      runHook postInstall
    '';
  };
in
if supported then
  stdenvNoCC.mkDerivation {
    pname = "wasixcc";
    inherit version;
    dontUnpack = true;

    # Update instructions:
    # 1) Update `src.rev` and `src.hash` to the target wasix-org/wasixcc commit.
    # 2) If Cargo dependencies changed, run `nix build .#wasixcc` and update cargoHash if Nix asks.
    # 3) Keep wrapper env vars aligned with pkgs/default.nix toolchain env exports.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/libexec"

      cp "${wasixccRaw}/libexec/wasixccenv" "$out/libexec/wasixccenv"

      for cmd in wasixcc 'wasix++' wasixcc++ wasixar wasixnm wasixranlib wasixld wasixccenv; do
        printf '%s\n' \
          '#!${bash}/bin/bash' \
          'set -euo pipefail' \
          'export WASIXCC_LLVM_LOCATION="${wasixLlvm}"' \
          'export WASIXCC_BINARYEN_LOCATION="${binaryen}"' \
          'export WASIXCC_SYSROOT_PREFIX="${wasixSysroot}"' \
          "exec -a \"\$0\" \"$out/libexec/wasixccenv\" \"\$@\"" \
          > "$out/bin/$cmd"
        chmod +x "$out/bin/$cmd"
      done

      runHook postInstall
    '';
  }
else
  throw "wasixcc package currently supports only x86_64-linux; current system is ${stdenv.hostPlatform.system}"
