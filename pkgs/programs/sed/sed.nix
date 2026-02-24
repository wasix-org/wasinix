{ lib, toolchain, gnused, ... }:
(gnused.overrideAttrs (old: {
  preConfigure = (old.preConfigure or "") + ''

    ${toolchain.commonPreConfigure}
  '';
  meta = old.meta // {
    platforms = lib.platforms.all;
  };
  hardeningDisable = [ "all" ];
  postInstall = (old.postInstall or "") + ''
    if [ -f "$out/bin/sed" ]; then
      mv "$out/bin/sed" "$out/bin/sed.wasm"
    fi
  '';
}))
