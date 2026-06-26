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
      configureFlags = ["--with-regex=none"];
      preConfigure = ''
        export CPPFLAGS="''${CPPFLAGS-} -I${nc.dev}/include -I${nc.dev}/include/ncursesw -Dwinch=less_winch"
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
      overrideAttrs = old: {
        patches = (old.patches or []) ++ [./patches/0001-wasix-term-fallback.patch];
        meta = (old.meta or {}) // {platforms = (old.meta.platforms or []) ++ ["wasm32-wasi"];};
        # upstream version is "685"; auto-pad would give 685.0.0, we want 685.0.1.
        passthru = (old.passthru or {}) // {wasmer.version = "685.0.1";};
      };
    } (prev.less.override {pcre2 = null;})
  )
