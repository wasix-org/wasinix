{
  entry,
  harnesses,
  packageForEntry,
  packages,
  pkgs,
  ...
}: let
  port =
    9000
    + pkgs.lib.toInt (pkgs.lib.versions.minor (packageForEntry packages entry).version)
    + (
      if pkgs.lib.hasSuffix "-int64" entry.name
      then 100
      else 0
    );
in {
  mysql = harnesses.hostShell {
    name = "${entry.name}-mysql";
    hostPackages = [pkgs.mariadb];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    timeout = 900;
    script = ''
      mariadb-install-db \
        --datadir="$PWD/db" \
        --auth-root-authentication-method=normal \
        --skip-test-db >/dev/null
      mariadbd \
        --datadir="$PWD/db" \
        --socket="$PWD/mariadb.sock" \
        --bind-address=127.0.0.1 \
        --port=${toString port} \
        --skip-networking=0 >mariadb.log 2>&1 &
      mariadb_pid=$!
      trap 'kill "$mariadb_pid" 2>/dev/null || true; wait "$mariadb_pid" 2>/dev/null || true' EXIT

      for _ in $(seq 1 60); do
        mariadb-admin --host=127.0.0.1 --port=${toString port} --user=root ping >/dev/null 2>&1 && break
        sleep 1
      done
      mariadb-admin --host=127.0.0.1 --port=${toString port} --user=root ping

      cp ${./mysql.php} mysql.php
      php mysql.php ${toString port}
    '';
  };
}
