# mysqlclient for wasix. setup.py probes a literal `pkg-config` (the cross
# wrapper is prefixed, so nothing is found) and mariadb_config is a target
# binary that can't run at build; feed the flags directly. Derive them from
# libmariadb.pc via the cross pkg-config wrapper (the .pc is normalised in
# packages/mariadb-connector-c_3_3.nix) so they track the connector's real
# deps instead of a hand-listed closure. No suite: the tests need a running
# MySQL server.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  preConfigure = ''
    export MYSQLCLIENT_CFLAGS="$($PKG_CONFIG --cflags libmariadb)"
    export MYSQLCLIENT_LDFLAGS="$($PKG_CONFIG --static --libs libmariadb)"
  '';
}
pyprev.mysqlclient
