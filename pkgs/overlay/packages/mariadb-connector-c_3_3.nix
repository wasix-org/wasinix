# mariadb-connector-c (libmysqlclient) for wasix, mysqlclient's C backend.
# libmariadb.a itself builds clean; only the unit-test binaries fail to link
# (getlogin is absent from wasix libc), and they could never run cross anyway.
# curl is only used by the remote_io plugin; off, so consumers linking the
# static archive don't have to close libcurl's references too.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  cmakeFlags = [
    "-DWITH_UNIT_TESTS=OFF"
    "-DWITH_CURL=OFF"
  ];
  # The generated libmariadb.pc records its static deps as "-l/nix/store/.../
  # libFOO.a" - a -l with an absolute archive path, which no linker accepts.
  # Strip the -l so the path stands alone (linkers take absolute .a paths), so
  # `pkg-config --static --libs libmariadb` is usable (see mysqlclient.nix).
  # postFixup: the pkgconfig files have settled in $dev by now.
  postFixup = ''
    for pc in "$dev"/lib/pkgconfig/*.pc; do
      [ -f "$pc" ] || continue
      sed -i 's#-l\(/nix/store/[^ ]*\.a\)#\1#g' "$pc"
    done
  '';
  # pvio_socket.c needs poll/POLLIN, which only the PIC sysroots declare.
  passthru.wasix.supportedProfiles = helpers.profiles.pic;
}
prev.mariadb-connector-c_3_3
