# ncurses auto-threads (final.ncurses). enableTiny, no nls/gettext/file.
{
  final,
  prev,
  helpers,
  nixpkgs,
  ...
}: let
  nc = final.ncurses;
in
  helpers.wasmRename {wasmName = "nano";} (
    helpers.libTweaks {
      passthru.wasinix.shipped = true;
      configureFlags = ["--with-ncursesw"];
      preConfigure = ''
        export CPPFLAGS="''${CPPFLAGS-} -I${nc.dev}/include -I${nc.dev}/include/ncursesw"
        export LDFLAGS="''${LDFLAGS-} -L${nc.out}/lib -static"
        export PKG_CONFIG_PATH="${nc.dev}/lib/pkgconfig"
        export PKG_CONFIG="pkg-config --static"
        if [ -f "${nc.out}/lib/libtinfow.a" ]; then
          export LIBS="''${LIBS-} ${nc.out}/lib/libncursesw.a ${nc.out}/lib/libtinfow.a"
        elif [ -f "${nc.out}/lib/libtinfo.a" ]; then
          export LIBS="''${LIBS-} ${nc.out}/lib/libncursesw.a ${nc.out}/lib/libtinfo.a"
        else
          export LIBS="''${LIBS-} ${nc.out}/lib/libncursesw.a"
        fi
      '';
      patches = [./patches/0002-wasix-runtime-and-config-tolerance.patch];
      postInstall = ''rm -f "$out/bin/rnano"'';
    } (final.callPackage "${nixpkgs}/pkgs/by-name/na/nano/package.nix" {
      enableNls = false;
      enableTiny = true;
      gettext = null;
      file = null;
    })
  )
