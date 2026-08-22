{
  exposeExtendedPackage,
  package,
  pkgs,
}: let
  patches = [
    ../../../patches/wasmer-signal-inherit-on-fork.patch
    ../../../patches/wasmer-futex-wake-lost-wakeup.patch
    ../../../patches/wasmer-fd-sync-rights-durability.patch
    ../../../patches/wasmer-fd-sync-directory.patch
    ../../../patches/wasmer-path-rename-hardlink.patch
    ../../../patches/wasmer-fd-readdir-stable-cookie.patch
    ../../../patches/wasmer-fd-filestat-stale-size.patch
    ../../../patches/wasmer-isatty-non-tty-unknown.patch
    ../../../patches/wasmer-forward-term-on-tty.patch
    ../../../patches/wasmer-dev-fd.patch
    ../../../patches/wasmer-epoll-stale-handler-deadlock.patch
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
  exposeExtendedPackage {
    inherit src cargoArtifacts;
    patches = [];
    postBuild = ''
      install -Dm644 ${cargoArtifacts}/wasmer.h lib/c-api/wasmer.h
    '';
  }
