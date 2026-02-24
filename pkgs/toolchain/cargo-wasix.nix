{
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  stdenv,
  bash,
  cargo,
  rustup,
  wasixRustToolchain,
  wasixcc,
  wasixLlvm,
  binaryen,
  wasixSysroot,
}:
let
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "cargo-wasix";
    # v0.1.25 parses wasm with walrus before invoking wasm-opt.
    # Pin to a newer commit that removed that parser path.
    rev = "9c0f8fd306c265734fdee7d941bc39641dc27c80";
    hash = "sha256-U1zG+xBzPiQVrgEJDqsAypFBVjPO7XZr8v+vfZGG+s0=";
  };

  cargoToml = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
  version = cargoToml.package.version;

  supported = stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64;

  wasixRustupToolchain = stdenvNoCC.mkDerivation {
    pname = "wasix-rustup-toolchain";
    inherit version;
    dontUnpack = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a "${wasixRustToolchain}"/. "$out"/
      chmod -R u+w "$out"

      cargo_bin="${cargo}/bin/.cargo-wrapped"
      if [ ! -x "$cargo_bin" ]; then
        cargo_bin="${cargo}/bin/cargo"
      fi
      ln -sf "$cargo_bin" "$out/bin/cargo"
      runHook postInstall
    '';
  };

  cargoWasixRaw = rustPlatform.buildRustPackage {
    pname = "cargo-wasix-raw";
    inherit version src;
    cargoLock.lockFile = ./cargo-wasix.Cargo.lock;

    doCheck = false;
    prePatch = ''
      cp ${./cargo-wasix.Cargo.lock} Cargo.lock
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      cp "$(find target -type f -path '*/release/cargo-wasix' | head -n 1)" "$out/bin/cargo-wasix"
      runHook postInstall
    '';
  };
in
if supported then
  stdenvNoCC.mkDerivation {
    pname = "cargo-wasix";
    inherit version;
    dontUnpack = true;

    # Update instructions:
    # 1) Update `src.rev` and `src.hash` to the target wasix-org/cargo-wasix revision.
    # 2) Run `nix build .#cargo-wasix` and update cargoHash if Nix asks.
    # 3) Keep wrapper env vars aligned with pkgs/default.nix toolchain env exports.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/libexec"

      cp "${cargoWasixRaw}/bin/cargo-wasix" "$out/libexec/cargo-wasix"

      cat > "$out/bin/cargo-wasix" <<EOF
#!${bash}/bin/bash
set -euo pipefail

export PATH="${rustup}/bin:${wasixcc}/bin:\$PATH"
export WASIXCC_LLVM_LOCATION="${wasixLlvm}/bin"
export WASIXCC_BINARYEN_LOCATION="${binaryen}/bin"
export WASIXCC_SYSROOT_PREFIX="${wasixSysroot}"
export WASIXCC_AUTOCONF_WORKAROUNDS=yes
export CC=wasixcc
export CXX=wasix++
export LD=wasixld
export AR=wasixar
export NM=wasixnm
export RANLIB=wasixranlib
export WASIXCC_RUN_WASM_OPT=no
if [ -z "\''${WASM_OPT:-}" ]; then
  export WASM_OPT="${binaryen}/bin/wasm-opt"
fi
export CARGO_WASIX_OFFLINE=1

"${rustup}/bin/rustup" toolchain remove wasix >/dev/null 2>&1 || true
"${rustup}/bin/rustup" toolchain link wasix "${wasixRustupToolchain}" >/dev/null
"${rustup}/bin/rustup" toolchain remove wasix-default >/dev/null 2>&1 || true
"${rustup}/bin/rustup" toolchain link wasix-default "${wasixRustupToolchain}" >/dev/null
"${rustup}/bin/rustup" default wasix-default >/dev/null

script_dir="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
exec "\$script_dir/../libexec/cargo-wasix" "\$@"
EOF
      chmod +x "$out/bin/cargo-wasix"

      runHook postInstall
    '';
  }
else
  throw "cargo-wasix package currently supports only x86_64-linux; current system is ${stdenv.hostPlatform.system}"
