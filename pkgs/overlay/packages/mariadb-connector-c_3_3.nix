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
  # pvio_socket.c needs poll/POLLIN, which only the PIC sysroots declare.
  passthru.wasix.supportedProfiles = helpers.profiles.pic;
}
prev.mariadb-connector-c_3_3
