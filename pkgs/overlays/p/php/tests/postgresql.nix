{
  entry,
  harnesses,
  packageForEntry,
  packages,
  pkgs,
  ...
}: let
  port =
    8900
    + pkgs.lib.toInt (pkgs.lib.versions.minor (packageForEntry packages entry).version)
    + (
      if pkgs.lib.hasSuffix "-int64" entry.name
      then 100
      else 0
    );
in {
  postgresql = harnesses.hostShell {
    name = "${entry.name}-postgresql";
    hostPackages = [pkgs.postgresql];
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--net"];
    timeout = 900;
    script = ''
      initdb -D db -U postgres --no-locale --encoding=UTF8 >/dev/null
      postgres -D db -k "$PWD" -h 127.0.0.1 -p ${toString port} >postgres.log 2>&1 &
      postgres_pid=$!
      trap 'kill "$postgres_pid" 2>/dev/null || true; wait "$postgres_pid" 2>/dev/null || true' EXIT

      for _ in $(seq 1 60); do
        pg_isready -h 127.0.0.1 -p ${toString port} -U postgres >/dev/null 2>&1 && break
        sleep 1
      done
      pg_isready -h 127.0.0.1 -p ${toString port} -U postgres

      cp ${./postgresql.php} postgresql.php
      php postgresql.php ${toString port}
    '';
  };
}
