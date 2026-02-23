{ lib, nixpkgs, toolchain, callPackage, ncurses, ... }:
(callPackage "${nixpkgs}/pkgs/by-name/na/nano/package.nix" {
  enableNls = false;
  enableTiny = true;
  gettext = null;
  file = null;
  inherit ncurses;
}).overrideAttrs (old: {
  preConfigure = (old.preConfigure or "") + ''
    ${toolchain.commonPreConfigure}
    export CPPFLAGS="''${CPPFLAGS-} -I${ncurses.dev}/include -I${ncurses.dev}/include/ncursesw"
    export LDFLAGS="''${LDFLAGS-} -L${ncurses.out}/lib -static"
    export PKG_CONFIG_PATH="${ncurses.dev}/lib/pkgconfig"
    export PKG_CONFIG="pkg-config --static"
    if [ -f "${ncurses.out}/lib/libtinfow.a" ]; then
      export LIBS="''${LIBS-} ${ncurses.out}/lib/libncursesw.a ${ncurses.out}/lib/libtinfow.a"
    elif [ -f "${ncurses.out}/lib/libtinfo.a" ]; then
      export LIBS="''${LIBS-} ${ncurses.out}/lib/libncursesw.a ${ncurses.out}/lib/libtinfo.a"
    else
      export LIBS="''${LIBS-} ${ncurses.out}/lib/libncursesw.a"
    fi
  '';
  configureFlags = (old.configureFlags or [ ]) ++ [
    "--host=${toolchain.host}"
    "--with-ncursesw"
  ];
  patches = (old.patches or [ ]) ++ [
    ./patches/0002-wasix-runtime-and-config-tolerance.patch
  ];
  hardeningDisable = [ "all" ];
  postInstall = (lib.optionalString (old.postInstall != null) old.postInstall) + ''
    if [ -f "$out/bin/nano" ]; then
      mv "$out/bin/nano" "$out/bin/nano.wasm"
    fi
    rm -f "$out/bin/rnano"
  '';
})
