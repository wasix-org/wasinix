{
  exposeNativePackage,
  extendPackage,
  package,
  pkgs,
}: let
  patches = [
    ./wasmer-futex-wake-lost-wakeup.patch
    ./wasmer-fd-sync-rights-durability.patch
    ./wasmer-fd-sync-directory.patch
    ./wasmer-path-rename-hardlink.patch
    ./wasmer-fd-readdir-stable-cookie.patch
    ./wasmer-fd-filestat-stale-size.patch
    ./wasmer-isatty-non-tty-unknown.patch
    ./wasmer-forward-term-on-tty.patch
    ./wasmer-dev-fd.patch
    ./wasmer-epoll-stale-handler-deadlock.patch
  ];
  src = pkgs.applyPatches {
    name = "${package.name}-patched-source";
    inherit (package) src;
    inherit patches;
  };
  cargoArtifacts = package.cargoArtifacts.overrideAttrs (old: {
    inherit src;
    patches = [];
    postInstall =
      (old.postInstall or "")
      + ''
        install -Dm644 target/release/build/wasmer-c-api-*/out/wasmer.h "$out/wasmer.h"
      '';
  });
in
  exposeNativePackage (extendPackage package {
    inherit src cargoArtifacts;
    patches = [];
    postBuild = ''
      install -Dm644 ${cargoArtifacts}/wasmer.h lib/c-api/wasmer.h
    '';
  })
