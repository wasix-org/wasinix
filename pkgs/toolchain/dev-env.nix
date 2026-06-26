# Shell env fragments for driving wasixcc outside the cross stdenv — the devShell
# and the env-injection link test. (The cross stdenv itself, used by every
# package, gets these via mk-wasix-stdenv's shim instead.) The per-profile
# `toolchains` set and these consumers share one source for the env.
{
  pkgs,
  toolchainPkgs,
}: {
  wasmExceptions ? null,
  pic ? false,
}: let
  lib = pkgs.lib;
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
  commonPreConfigure = ''
    export PATH="${toolchainPkgs.wasixcc}/bin:$PATH"
    ${toolchainEnv}
    ${ccEnv}
  '';
in {
  inherit toolchainEnv ccEnv commonPreConfigure profileEnv;
}
