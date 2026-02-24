{ nixpkgs, toolchain, callPackage, ... }:
(callPackage "${nixpkgs}/pkgs/development/libraries/ncurses/default.nix" {
  enableStatic = true;
  withCxx = false;
}).overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ toolchain.wasixcc ];
  preConfigure = (old.preConfigure or "") + ''
    ${toolchain.commonPreConfigure}
  '';
  configureFlags = [
    "--host=${toolchain.host}"
    "--with-build-cc=${toolchain.buildCc}"
    "--with-build-cpp=${toolchain.buildCc}"
    "--with-fallbacks=vt220,xterm,xterm-256color,screen,screen-256color,ansi,linux,dumb"
    "--without-tests"
    "--without-shared"
    "--with-static"
    "--enable-widec"
    "--disable-stripping"
    "--with-progs"
  ];
  patches = (old.patches or [ ]) ++ [
    ./patches/0001-default-term-when-unset.patch
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
  hardeningDisable = [ "all" ];

  # TODO: expose more commands, not just clear, reset, tput ?

  postInstall = (old.postInstall or "") + ''
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
        ! -name 'clear.wasm' \
        ! -name 'reset.wasm' \
        ! -name 'tput.wasm' \
        -delete
      find "$out/bin" -mindepth 1 -maxdepth 1 -type l -delete
    fi

    if [ -n "''${dev-}" ] && [ -d "$dev/bin" ]; then
      rm -rf "$dev/bin"
    fi
  '';
  postFixup = "";
})
