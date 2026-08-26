# wasixcc, the WASIX cc driver. The wasixccenv binary is a product
# (`native/wasixcc`); this wraps it, holding one makeWrapper wrapper
# per tool name with the toolchain locations from env.nix baked in.
{
  lib,
  stdenvNoCC,
  buildPackages,
  makeWrapper,
  wasixcc-unwrapped,
  wasix-llvm,
  binaryen,
  wasix-sysroot,
  ...
}: let
  inherit (buildPackages) nix-update-script;
  env = import ../../../toolchain/env.nix {inherit lib;};
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
      # The recipe is native/wasixcc, which carries the version and the
      # src; the wrapper adds the toolchain locations and declares the bump.
      unwrapped = wasixccUnwrapped;
      updateScript = {
        command = nix-update-script {extraArgs = ["--flake"];};
        attrPath = "packages.native.wasixcc-unwrapped";
        accepts = ["release" "revision"];
        source = {
          kind = "github";
          owner = "wasix-org";
          repo = "wasixcc";
        };
      };
    };

    meta = {
      description = "WASIX C/C++ compiler driver (clang/lld/binaryen orchestrator), wrapped with the from-source toolchain";
      longDescription = "A C and C++ compiler driver that combines the WASIX LLVM, linker, Binaryen, and sysroot components into a relocatable toolchain.";
      homepage = "https://github.com/wasix-org/wasixcc";
      changelog = "https://github.com/wasix-org/wasixcc/releases/tag/v${version}";
      license = with lib.licenses; [mit asl20];
      # The wrapped toolchain (LLVM fork, sysroot) is only built for x86_64-linux.
      platforms = ["x86_64-linux"];
      mainProgram = "wasixcc";
    };
  }
