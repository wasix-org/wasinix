{
  pkgs,
  toolchainPkgs,
}: {
  name,
  wasmExceptions ? null,
  pic ? false,
}: let
  lib = pkgs.lib;
  buildCc = "${pkgs.buildPackages.stdenv.cc}/bin/cc";
  host = "wasm32-wasix";
  crossSystem = {
    # Keep nixpkgs parser-compatible triple and pin WASIX tooling explicitly.
    config = "wasm32-unknown-wasi";
    useLLVM = true;
    isWasix = true;
  };
  profileEnv = lib.concatStringsSep "\n" (
    lib.optional (wasmExceptions != null)
    "export WASIXCC_WASM_EXCEPTIONS=${lib.escapeShellArg wasmExceptions}"
    ++ [
      "export WASIXCC_PIC=${
        if pic
        then "yes"
        else "no"
      }"
    ]
  );
  toolchainEnv = ''
    export WASIXCC_LLVM_LOCATION="${toolchainPkgs.wasixLlvm}/bin"
    export WASIXCC_SYSROOT_PREFIX="${toolchainPkgs.wasixSysroot}"
    export WASIXCC_BINARYEN_LOCATION="${toolchainPkgs.binaryen}/bin"
    export WASIXCC_AUTOCONF_WORKAROUNDS=yes
    ${profileEnv}
  '';
  ccEnv = ''
    export CC=wasixcc
    export CXX=wasix++
    export LD=wasixld
    export AR=wasixar
    export NM=wasixnm
    export RANLIB=wasixranlib
    export WASIXCC_RUN_WASM_OPT=no
  '';
in
  toolchainPkgs
  // {
    profileName = name;
    inherit buildCc host crossSystem wasmExceptions pic toolchainEnv ccEnv;

    commonPreConfigure = ''
      export PATH="${toolchainPkgs.wasixcc}/bin:$PATH"
      ${toolchainEnv}
      ${ccEnv}
    '';
  }
