{
  lib,
  toolchain,
  gnused,
  ...
}: ((gnused.override {stdenv = toolchain.stdenv;}).overrideAttrs (old: {
  preConfigure =
    (old.preConfigure or "")
    + ''

    '';
  meta =
    old.meta
    // {
      platforms = lib.platforms.all;
    };
  hardeningDisable = ["all"];
  postInstall =
    (old.postInstall or "")
    + ''
      if [ -f "$out/bin/sed" ]; then
        mv "$out/bin/sed" "$out/bin/sed.wasm"
      fi
    '';
}))
