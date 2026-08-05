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

  # Untagged rev: the overlay-registry switch, the wasixcc CC/EH auto-config and
  # the binaryen 130 bump all landed after v0.1.29, and upstream has cut no tag
  # for 0.1.30/0.1.31.
  version = "0.1.29";
  src = fetchFromGitHub {
    owner = "wasix-org";
    repo = "cargo-wasix";
    rev = "89980447bc9b6c001f5631c1598780d3dcb6f17d";
    hash = "sha256-0spEK/HmE7qdglHBMxhzUc/O/otKu5imPsEta1y39v4=";
  };

  cargoWasixUnwrapped = rustPlatform.buildRustPackage {
    pname = "cargo-wasix-unwrapped";
    inherit version src;
    cargoHash = "sha256-mOPo9sNAOflMY2hHpKpzUlKMFXYr0O8r/7QGtOoDtUU=";

    doCheck = false;

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
        --set-default WASM_OPT "${binaryen}/bin/wasm-opt" \
        --run ${lib.escapeShellArg rustupLink}
      runHook postInstall
    '';

    passthru = {
      unwrapped = cargoWasixUnwrapped;
      # nix-update needs version + src on the drv it evals: the wrapper has
      # neither, so point it at the unwrapped package
      updateScript = {
        command = nix-update-script {extraArgs = ["--flake"];};
        attrPath = "toolchain.cargo-wasix.unwrapped";
      };

      wasix.updateNotes = [
        {message = "cargo-wasix is pinned to an untagged rev; go back to `tag = \"v\${version}\"` once upstream tags 0.1.31 or later";}
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
