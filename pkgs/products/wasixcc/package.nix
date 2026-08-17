# wasixcc, the WASIX cc driver. The wasixccenv binary is a product
# (products/wasixcc); this wraps it, holding one makeWrapper wrapper
# per tool name with the toolchain locations from env.nix baked in.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  nix-update-script,
  wasixcc-unwrapped,
  wasix-llvm,
  binaryen,
  wasix-sysroot,
  ...
}: let
  env = import ../../toolchain/env.nix {inherit lib;};
  wasixccUnwrapped = wasixcc-unwrapped;
  wasixLlvm = wasix-llvm;
  wasixSysroot = wasix-sysroot;
  inherit (wasixccUnwrapped) version;

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
      # The recipe is products/wasixcc, which carries the version and the
      # src; the wrapper adds the toolchain locations and declares the bump.
      unwrapped = wasixccUnwrapped;
      updateScript = {
        command = nix-update-script {extraArgs = ["--flake"];};
        attrPath = "toolchain.wasixcc.unwrapped";
        accepts = ["release" "revision"];
        source = {
          kind = "github";
          owner = "wasix-org";
          repo = "wasixcc";
        };
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
