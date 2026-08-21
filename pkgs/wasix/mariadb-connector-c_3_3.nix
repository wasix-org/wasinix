# mariadb-connector-c for wasix, mysqlclient's C backend. Its unit tests need getlogin.
{
  exposeExtendedPackage,
  profileSets,
}:
exposeExtendedPackage {
  # remote_io defaults to a loadable module, which the static build drops
  # entirely; STATIC compiles it into libmariadb.a and puts curl on the link.
  cmakeFlags = [
    "-DWITH_UNIT_TESTS=OFF"
    "-DCLIENT_PLUGIN_REMOTE_IO=STATIC"
  ];
  # The generated libmariadb.pc records static deps as "-l/nix/store/...libFOO.a", an
  # absolute archive path behind a -l, which no linker accepts. It also omits curl:
  # the connector gates that on REMOTEIO_PLUGIN_TYPE, which its cmake never sets, so
  # a static consumer would link libmariadb.a with curl_easy_* undefined.
  postFixup = ''
    for pc in "$dev"/lib/pkgconfig/*.pc; do
      [ -f "$pc" ] || continue
      sed -i 's#-l\(/nix/store/[^ ]*\.a\)#\1#g' "$pc"
    done
    echo "Requires.private: libcurl" >>"$dev/lib/pkgconfig/libmariadb.pc"
  '';
  # pvio_socket.c needs poll/POLLIN, which only the PIC sysroots declare.
  passthru.wasix.supportedProfiles = profileSets.pic;
}
