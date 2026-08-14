# Library ncurses (widec, static, no progs). The program ncurses (clear/reset/
# tput) is a separate package. --host comes from the cross stdenv's
# configurePlatforms; --with-build-cc points at the build-platform cc (ncurses
# builds tic etc. natively during the build).
{
  final,
  prev,
  helpers,
  ...
}: let
  buildCc = "${final.buildPackages.stdenv.cc}/bin/cc";
in
  helpers.libTweaks {
    # The link smoke fails without diagnostics, likely on the alias symlink
    # farm (libtinfo/libcurses point at libncursesw.a); untriaged,
    # WASIX-TODO.md. The CLIs that link the library cover it at runtime.
    passthru.wasix.smokeTest = false;
    configureFlags = _: [
      "--with-build-cc=${buildCc}"
      "--with-build-cpp=${buildCc}"
      "--with-fallbacks=vt220,xterm,xterm-256color,screen,screen-256color,ansi,linux,dumb"
      "--without-tests"
      "--without-progs"
      "--without-shared"
      "--with-static"
      "--enable-widec"
      # withCxx=false's flag is dropped by this configureFlags override; restate
      # it. The C++ bindings use try/catch, which off-EH -fno-exceptions rejects.
      "--without-cxx-binding"
    ];
    # widec build ships libncursesw.a; add the non-suffixed compat symlinks a
    # normal ncurses provides, so -lncurses / -ltinfo (bash's termcap) resolve.
    postInstall = ''
      for base in ncurses form menu panel; do
        if [ -f "$out/lib/lib''${base}w.a" ] && [ ! -e "$out/lib/lib''${base}.a" ]; then
          ln -s "lib''${base}w.a" "$out/lib/lib''${base}.a"
        fi
      done
      for alias in libtinfo libtinfow libtermcap libcurses; do
        if [ ! -e "$out/lib/$alias.a" ]; then
          ln -s libncursesw.a "$out/lib/$alias.a"
        fi
      done
    '';
    # In split-output static cross builds, ncurses creates pkg-config alias
    # symlinks that can dangle during fixup. Materialize them first.
    preFixup = ''
      pcdir="$dev/lib/pkgconfig"
      if [ -d "$pcdir" ]; then
        materialize_pc() {
          dst="$1"
          shift
          rm -f "$dst"
          for src in "$@"; do
            if [ -e "$src" ]; then
              cp -L "$src" "$dst"
              return 0
            fi
          done
        }
        materialize_pc "$pcdir/tinfo.pc" "$pcdir/ncurses.pc" "$pcdir/tic.pc"
        materialize_pc "$pcdir/tinfow.pc" "$pcdir/ncursesw.pc" "$pcdir/ticw.pc"
        materialize_pc "$pcdir/tic.pc" "$pcdir/tinfo.pc" "$pcdir/ncurses.pc"
        materialize_pc "$pcdir/ticw.pc" "$pcdir/tinfow.pc" "$pcdir/ncursesw.pc"
      fi
    '';
  } (prev.ncurses.override {
    enableStatic = true;
    withCxx = false;
  })
