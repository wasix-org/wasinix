{
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  stdenv,
  bash,
  rustup,
  wasixRustToolchain,
  wasixcc,
  wasixLlvm,
  binaryen,
  wasixSysroot,
}: let
  # version is the source of truth; the tag is `v${version}`. (The old
  # `fromTOML (readFile "${src}/Cargo.toml")` was IFD — it forced the src to
  # realise just to read the version.)
  version = "0.1.28"; # past v0.1.25, which parsed wasm with walrus before wasm-opt.
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "cargo-wasix";
    tag = "v${version}";
    hash = "sha256-PQUQtvaoKUoNeITQ47gNPMvj9Odbaz9x3538f1D4WUE=";
  };

  supported = stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64;

  cargoWasixRaw = rustPlatform.buildRustPackage {
    pname = "cargo-wasix-raw";
    inherit version src;
    # Upstream ships no Cargo.lock, so cargoHash/fetchCargoVendor can't be used (it
    # hard-requires one). Carry a committed lock and vendor from it via importCargoLock.
    # Regenerate with `cargo generate-lockfile` against a new src when bumping.
    cargoLock.lockFile = ./cargo-wasix.Cargo.lock;

    doCheck = false;
    # cargoSetupHook vendors from the lock but doesn't write Cargo.lock into the (lockless)
    # source, so the offline cargo build wouldn't find one — put it there ourselves.
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
  if supported
  then
    stdenvNoCC.mkDerivation {
      pname = "cargo-wasix";
      inherit version;
      dontUnpack = true;

      # Update instructions:
      # 1) Update `src.rev` and `src.hash` to the target wasix-org/cargo-wasix revision.
      # 2) Regenerate ./cargo-wasix.Cargo.lock (`cargo generate-lockfile`) — upstream
      #    ships none, so it can't be vendored via cargoHash/nix-update.
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
        "${rustup}/bin/rustup" toolchain link wasix "${wasixRustToolchain}" >/dev/null
        "${rustup}/bin/rustup" toolchain remove wasix-default >/dev/null 2>&1 || true
        "${rustup}/bin/rustup" toolchain link wasix-default "${wasixRustToolchain}" >/dev/null
        "${rustup}/bin/rustup" default wasix-default >/dev/null

        script_dir="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
        exec "\$script_dir/../libexec/cargo-wasix" "\$@"
        EOF
              chmod +x "$out/bin/cargo-wasix"

              runHook postInstall
      '';
    }
  else throw "cargo-wasix package currently supports only x86_64-linux; current system is ${stdenv.hostPlatform.system}"
