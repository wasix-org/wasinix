# Program ncurses: builds tic/clear/reset/tput (--with-progs); ships only
# clear/reset/tput as *.wasm. Distinct from the `ncurses` library package.
{
  final,
  prev,
  helpers,
  ...
}: let
  buildCc = "${final.buildPackages.stdenv.cc}/bin/cc";
in
  helpers.libTweaks {
    overrideAttrs = old: {
      configureFlags = [
        "--with-build-cc=${buildCc}"
        "--with-build-cpp=${buildCc}"
        "--with-fallbacks=vt220,xterm,xterm-256color,screen,screen-256color,ansi,linux,dumb"
        "--without-tests"
        "--without-shared"
        "--with-static"
        "--enable-widec"
        "--disable-stripping"
        "--with-progs"
      ];
      patches = (old.patches or []) ++ [./patches/default-term-when-unset.patch];
      preFixup =
        (old.preFixup or "")
        + ''
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
      postInstall =
        (old.postInstall or "")
        + ''
          src_bin=""
          if [ -d "$out/bin" ]; then
            src_bin="$out/bin"
          elif [ -n "''${dev-}" ] && [ -d "$dev/bin" ]; then
            src_bin="$dev/bin"
            mkdir -p "$out/bin"
          fi
          if [ -n "$src_bin" ]; then
            for cmd in clear reset tput; do
              if [ -e "$src_bin/$cmd" ]; then
                cp -L "$src_bin/$cmd" "$out/bin/$cmd.wasm"
                chmod +x "$out/bin/$cmd.wasm"
              fi
            done
            find "$out/bin" -mindepth 1 -maxdepth 1 -type f \
              ! -name 'clear.wasm' ! -name 'reset.wasm' ! -name 'tput.wasm' -delete
            find "$out/bin" -mindepth 1 -maxdepth 1 -type l -delete
          fi
          if [ -n "''${dev-}" ] && [ -d "$dev/bin" ]; then
            rm -rf "$dev/bin"
          fi
        '';
      postFixup = "";
    };
  } (prev.ncurses.override {
    enableStatic = true;
    withCxx = false;
  })
