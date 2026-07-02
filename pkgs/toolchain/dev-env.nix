# Shell env fragments for driving wasixcc outside the cross stdenv — the devShell
# and the env-injection link test. (The cross stdenv itself, used by every
# package, gets these via set/stdenv.nix's shim instead.) All values come from
# the shared env contract in env.nix, so the consumers can't drift.
{
  pkgs,
  foundation,
}: {
  wasmExceptions ? null,
  pic ? false,
}: let
  env = import ./env.nix {inherit (pkgs) lib;};
  profileEnv = env.exportsOf (env.profileEnv {inherit wasmExceptions pic;});
  toolchainEnv = env.exportsOf (
    env.locationEnv {inherit (foundation) wasixLlvm binaryen wasixSysroot;}
    // env.autoconfEnv
    // env.profileEnv {inherit wasmExceptions pic;}
  );
  ccEnv = env.exportsOf env.ccEnv;
  commonPreConfigure = ''
    export PATH="${foundation.wasixcc}/bin:$PATH"
    ${toolchainEnv}
    ${ccEnv}
  '';
in {
  inherit toolchainEnv ccEnv commonPreConfigure profileEnv;
}
