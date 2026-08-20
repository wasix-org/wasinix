# ncurses auto-threads (final.ncurses, the library ncurses). less's "winch"
# signal handler clashes with ncurses' winch() under wasm → rename it.
{
  final,
  prev,
  helpers,
  ...
}: let
  nc = final.ncurses;
in
  helpers.wasmRename {wasmName = "less";} (
    helpers.libTweaks {
      passthru.wasinix.shipped = true;
      configureFlags = ["--with-regex=pcre2"];
      preConfigure = ''
        export CPPFLAGS="''${CPPFLAGS-} -I${nc.dev}/include -I${nc.dev}/include/ncursesw -Dwinch=less_winch"
        export LDFLAGS="''${LDFLAGS-} -L${nc.out}/lib -static"
        export PKG_CONFIG_PATH="${nc.dev}/lib/pkgconfig:${final.pcre2.dev}/lib/pkgconfig"
        export PKG_CONFIG="pkg-config --static"
        if [ -f "${nc.out}/lib/libtinfow.a" ]; then
          export LIBS="''${LIBS-} ${nc.out}/lib/libncursesw.a ${nc.out}/lib/libtinfow.a"
        elif [ -f "${nc.out}/lib/libtinfo.a" ]; then
          export LIBS="''${LIBS-} ${nc.out}/lib/libncursesw.a ${nc.out}/lib/libtinfo.a"
        else
          export LIBS="''${LIBS-} ${nc.out}/lib/libncursesw.a"
        fi
      '';
      patches = [./patches/0001-wasix-term-fallback.patch];
      meta.platforms = ["wasm32-wasi"];
    }
    prev.less
  )
