# cargo-wasix, the cargo subcommand driving WASIX builds. The binary is a
# binary is native/cargo-wasix-unwrapped; this wrapper pins the toolchain
# env (wasixcc + LLVM + binaryen + sysroot) and links the from-source rust
# toolchain into rustup before exec'ing.
{
  lib,
  stdenvNoCC,
  buildPackages,
  makeWrapper,
  rustup,
  cargo-wasix-unwrapped,
  wasix-rust,
  wasixcc,
  wasix-llvm,
  binaryen,
  wasix-sysroot,
  ...
}: let
  inherit (buildPackages) nix-update-script;
  env = import ../../../toolchain/env.nix {inherit lib;};
  cargoWasixUnwrapped = cargo-wasix-unwrapped;
  wasixRustToolchain = wasix-rust;
  wasixLlvm = wasix-llvm;
  wasixSysroot = wasix-sysroot;
  inherit (cargoWasixUnwrapped) version;

  # cargo-wasix resolves its toolchain through rustup; before exec, (re-)link
  # ours under the names it looks for. Idempotent, quiet on the happy path.
  rustupLink = ''
    "${lib.getExe rustup}" toolchain remove wasix >/dev/null 2>&1 || true
    "${lib.getExe rustup}" toolchain link wasix "${wasixRustToolchain}" >/dev/null || exit 1
    "${lib.getExe rustup}" toolchain remove wasix-default >/dev/null 2>&1 || true
    "${lib.getExe rustup}" toolchain link wasix-default "${wasixRustToolchain}" >/dev/null || exit 1
    "${lib.getExe rustup}" default wasix-default >/dev/null || exit 1
  '';
in
  stdenvNoCC.mkDerivation {
    pname = "cargo-wasix";
    inherit version;
    dontUnpack = true;

    nativeBuildInputs = [makeWrapper];

    installPhase = ''
      runHook preInstall
      install -Dm755 "${lib.getExe cargoWasixUnwrapped}" "$out/libexec/cargo-wasix"
      makeWrapper "$out/libexec/cargo-wasix" "$out/bin/cargo-wasix" \
        --prefix PATH : "${lib.makeBinPath [rustup wasixcc]}" \
        ${env.makeWrapperFlagsOf (
        env.locationEnv {inherit wasixLlvm binaryen wasixSysroot;}
        // env.autoconfEnv
        // env.ccEnv
        // {
          CARGO_WASIX_OFFLINE = "1";
          # Since 0.1.30 cargo-wasix writes overlay-registry source replacement
          # into the workspace .cargo/config.toml on build. Nix resolves from a
          # vendored `directory` source instead, so the write is at best a
          # warning about cargoSetupHook's own replace-with and at worst points
          # resolution at a network registry the sandbox can't reach.
          CARGO_WASIX_NO_REGISTRY_CONFIG = "1";
        }
      )} \
        --set-default WASM_OPT "${lib.getExe' binaryen "wasm-opt"}" \
        --run ${lib.escapeShellArg rustupLink}
      runHook postInstall
    '';

    passthru = {
      # The recipe is native/cargo-wasix, which carries the version and
      # the src; the wrapper adds the toolchain env and declares the bump.
      unwrapped = cargoWasixUnwrapped;
      # nix-update needs version + src on the drv it evals: the wrapper has
      # neither, so point it at the unwrapped package
      updateScript = {
        command = nix-update-script {extraArgs = ["--flake"];};
        attrPath = "packages.native.cargo-wasix-unwrapped";
        accepts = ["release" "revision"];
        source = {
          kind = "github";
          owner = "wasix-org";
          repo = "cargo-wasix";
        };
      };
    };

    meta = {
      description = "cargo subcommand driving WASIX builds, wrapped with the from-source wasix toolchain";
      longDescription = "A Cargo subcommand that builds Rust projects for WASIX using the repository's from-source compiler and runtime toolchain.";
      homepage = "https://github.com/wasix-org/cargo-wasix";
      changelog = "https://github.com/wasix-org/cargo-wasix/releases/tag/v${version}";
      license = with lib.licenses; [mit asl20];
      # The wrapped toolchain (LLVM fork, rust fork) is only built for x86_64-linux.
      platforms = ["x86_64-linux"];
      mainProgram = "cargo-wasix";
    };
  }
