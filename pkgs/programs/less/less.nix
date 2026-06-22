{
  lib,
  toolchain,
  less,
  ncurses,
  ...
}: ((less.override {
    inherit ncurses;
    pcre2 = null;
  }).overrideAttrs (old: {
    preConfigure =
      (old.preConfigure or "")
      + ''
        ${toolchain.commonPreConfigure}
        # less defines a signal handler named "winch" which collides with ncurses'
        # winch() symbol and causes invalid wasm due to signature mismatch.
        export CPPFLAGS="''${CPPFLAGS-} -I${ncurses.dev}/include -I${ncurses.dev}/include/ncursesw -Dwinch=less_winch"
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
    configureFlags =
      (old.configureFlags or [])
      ++ [
        "--host=${toolchain.host}"
        "--with-regex=none"
      ];
    patches =
      (old.patches or [])
      ++ [
        ./patches/0001-wasix-term-fallback.patch
      ];
    hardeningDisable = ["all"];
    meta =
      (old.meta or {})
      // {
        platforms = (old.meta.platforms or []) ++ ["wasm32-wasi"];
      };
    postInstall =
      (old.postInstall or "")
      + ''
        if [ -f "$out/bin/less" ]; then
          mv "$out/bin/less" "$out/bin/less.wasm"
        fi
      '';
  }))
