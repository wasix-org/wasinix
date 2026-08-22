{
  exposeExtendedPackage,
  package,
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
in
  exposeExtendedPackage {
    inherit patches;
    cargoArtifacts = package.cargoArtifacts.overrideAttrs (old: {
      patches = (old.patches or []) ++ patches;
    });
  }
