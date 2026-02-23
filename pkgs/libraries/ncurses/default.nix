{ nixpkgs, toolchain, callPackage, ... }:
(callPackage "${nixpkgs}/pkgs/development/libraries/ncurses/default.nix" {
  enableStatic = true;
  withCxx = false;
}).overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ toolchain.wasixcc ];
  preConfigure = (old.preConfigure or "") + ''
    ${toolchain.toolchainEnv}
    ${toolchain.ccEnv}
  '';
  configureFlags = [
    "--host=${toolchain.host}"
    "--with-build-cc=${toolchain.buildCc}"
    "--with-build-cpp=${toolchain.buildCc}"
    "--with-fallbacks=vt220,xterm,xterm-256color,screen,screen-256color,ansi,linux,dumb"
    "--without-tests"
    "--without-progs"
    "--without-shared"
    "--with-static"
    "--enable-widec"
  ];
  # In split-output static cross builds, ncurses creates pkg-config alias
  # symlinks that can dangle during fixup. Materialize them first.
  preFixup = (old.preFixup or "") + ''
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
})
