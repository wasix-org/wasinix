# cargo-wasix (the upstream build driver), wrapped for nix: the raw binary is
# built from source, and the bin/ entry point is a makeWrapper wrapper that
# pins the whole toolchain environment (wasixcc + LLVM + binaryen + sysroot)
# and links the from-source rust toolchain into rustup before exec'ing.
#
# Update instructions:
# 1) Update `version` and `src.hash` to the target wasix-org/cargo-wasix release.
# 2) Regenerate ./cargo-wasix.Cargo.lock (`cargo generate-lockfile`) — upstream
#    ships none, so it can't be vendored via cargoHash/nix-update.
# 3) Keep the wrapper env vars aligned with toolchain/dev-env.nix.
{
  lib,
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  makeWrapper,
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

  # cargo-wasix insists on resolving its toolchain through rustup; before exec,
  # (re-)link the from-source toolchain under the names it looks for. Idempotent
  # (remove-then-link), and quiet on the happy path.
  rustupLink = ''
    "${rustup}/bin/rustup" toolchain remove wasix >/dev/null 2>&1 || true
    "${rustup}/bin/rustup" toolchain link wasix "${wasixRustToolchain}" >/dev/null || exit 1
    "${rustup}/bin/rustup" toolchain remove wasix-default >/dev/null 2>&1 || true
    "${rustup}/bin/rustup" toolchain link wasix-default "${wasixRustToolchain}" >/dev/null || exit 1
    "${rustup}/bin/rustup" default wasix-default >/dev/null || exit 1
  '';
in
  stdenvNoCC.mkDerivation {
    pname = "cargo-wasix";
    inherit version;
    dontUnpack = true;

    nativeBuildInputs = [makeWrapper];

    installPhase = ''
      runHook preInstall
      install -Dm755 "${cargoWasixRaw}/bin/cargo-wasix" "$out/libexec/cargo-wasix"
      makeWrapper "$out/libexec/cargo-wasix" "$out/bin/cargo-wasix" \
        --prefix PATH : "${lib.makeBinPath [rustup wasixcc]}" \
        --set WASIXCC_LLVM_LOCATION "${wasixLlvm}/bin" \
        --set WASIXCC_BINARYEN_LOCATION "${binaryen}/bin" \
        --set WASIXCC_SYSROOT_PREFIX "${wasixSysroot}" \
        --set WASIXCC_AUTOCONF_WORKAROUNDS yes \
        --set WASIXCC_RUN_WASM_OPT no \
        --set CC wasixcc \
        --set CXX wasix++ \
        --set LD wasixld \
        --set AR wasixar \
        --set NM wasixnm \
        --set RANLIB wasixranlib \
        --set-default WASM_OPT "${binaryen}/bin/wasm-opt" \
        --set CARGO_WASIX_OFFLINE 1 \
        --run ${lib.escapeShellArg rustupLink}
      runHook postInstall
    '';

    meta = {
      description = "cargo subcommand driving WASIX builds, wrapped with the from-source wasix toolchain";
      homepage = "https://github.com/wasix-org/cargo-wasix";
      license = with lib.licenses; [mit asl20];
      # The wrapped toolchain (LLVM fork, rust fork) is only built for x86_64-linux.
      platforms = ["x86_64-linux"];
      mainProgram = "cargo-wasix";
    };
  }
