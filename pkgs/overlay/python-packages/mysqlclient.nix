# mysqlclient for wasix. setup.py probes a literal `pkg-config` (the cross
# wrapper is prefixed, so nothing is found) and mariadb_config is a target
# binary that can't run at build; feed the flags directly. The libs close
# libmariadb.a's references (openssl/zlib/zstd auto-thread as buildInputs).
{
  final,
  lib,
  pyprev,
  helpers,
  ...
}: let
  mariadb = final.libmysqlclient;
in
  helpers.libTweaks {
    env = {
      MYSQLCLIENT_CFLAGS = "-I${lib.getDev mariadb}/include/mariadb";
      MYSQLCLIENT_LDFLAGS = "-L${mariadb}/lib/mariadb -lmariadb -lssl -lcrypto -lz -lzstd";
    };
  }
  pyprev.mysqlclient
