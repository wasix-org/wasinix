# cargo-wasix, built from source; the bin/ wrapper pins the toolchain env
# (wasixcc + LLVM + binaryen + sysroot) and links the from-source rust toolchain
# into rustup before exec'ing.
{
  lib,
  stdenvNoCC,
  rustPlatform,
  fetchFromGitHub,
  makeWrapper,
  nix-update-script,
  rustup,
  wasixRustToolchain,
  wasixcc,
  wasixLlvm,
  binaryen,
  wasixSysroot,
}: let
  env = import ../env.nix {inherit lib;};

  version = "0.1.29";
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "cargo-wasix";
    tag = "v${version}";
    hash = "sha256-Gj0Qa3UXOCLQO0Ntyq8Zal5m5ro2CmEPXWT4cNBwkZI=";
  };

  cargoWasixUnwrapped = rustPlatform.buildRustPackage {
    pname = "cargo-wasix-unwrapped";
    inherit version src;
    # Upstream ships no Cargo.lock and cargoHash/fetchCargoVendor requires one,
    # so vendor from a committed lock via importCargoLock.
    cargoLock.lockFile = ./cargo-wasix.Cargo.lock;

    doCheck = false;
    # cargoSetupHook doesn't write Cargo.lock into the lockless source; the
    # offline cargo build needs it there.
    prePatch = ''
      cp ${./cargo-wasix.Cargo.lock} Cargo.lock
    '';

    # TODO: Is this necessary?
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      cp "$(find target -type f -path '*/release/cargo-wasix' | head -n 1)" "$out/bin/cargo-wasix"
      runHook postInstall
    '';
  };

  # cargo-wasix resolves its toolchain through rustup; before exec, (re-)link
  # ours under the names it looks for. Idempotent, quiet on the happy path.
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
      install -Dm755 "${cargoWasixUnwrapped}/bin/cargo-wasix" "$out/libexec/cargo-wasix"
      makeWrapper "$out/libexec/cargo-wasix" "$out/bin/cargo-wasix" \
        --prefix PATH : "${lib.makeBinPath [rustup wasixcc]}" \
        ${env.makeWrapperFlagsOf (
        env.locationEnv {inherit wasixLlvm binaryen wasixSysroot;}
        // env.autoconfEnv
        // env.ccEnv
        // {CARGO_WASIX_OFFLINE = "1";}
      )} \
        --set-default WASM_OPT "${binaryen}/bin/wasm-opt" \
        --run ${lib.escapeShellArg rustupLink}
      runHook postInstall
    '';

    passthru = {
      unwrapped = cargoWasixUnwrapped;
      # nix-update needs version + src on the drv it evals: the wrapper has
      # neither, so point it at the unwrapped package
      updateScript = {
        # --src-only: upstream ships no Cargo.lock, so nix-update's lockfile
        # extraction cannot work; the vendored lock is the regen hook's job
        command = nix-update-script {extraArgs = ["--flake" "--src-only"];};
        attrPath = "toolchain.cargo-wasix.unwrapped";
      };
      # default predicate: fires in the change that bumps cargo-wasix
      wasix.updateNotes = [
        {message = "upstream may ship its own Cargo.lock; try dropping the vendored cargo-wasix.Cargo.lock, the regen hook in update.py, and the importCargoLock plumbing";}
      ];
    };

    meta = {
      description = "cargo subcommand driving WASIX builds, wrapped with the from-source wasix toolchain";
      homepage = "https://github.com/wasix-org/cargo-wasix";
      license = with lib.licenses; [mit asl20];
      # The wrapped toolchain (LLVM fork, rust fork) is only built for x86_64-linux.
      platforms = ["x86_64-linux"];
      mainProgram = "cargo-wasix";
    };
  }
