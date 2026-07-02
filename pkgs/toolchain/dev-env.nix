# Shell env fragments for driving wasixcc outside the cross stdenv (devShell,
# link test); the stdenv itself gets the same values via set/stdenv.nix. All
# values come from env.nix so consumers can't drift.
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
