{
  commands,
  pkgs,
  entry,
  harnesses,
  packageForEntry,
  packages,
  ...
}: let
  psql = builtins.attrValues entry.commands;
  nativePsql = [pkgs."postgresql_${toString (pkgs.lib.versions.major (packageForEntry packages entry).version)}"];
in {
  version = harnesses.wasixShell {
    name = "psql-version";
    shell = commands.bash;
    commands = psql;
    script = "psql --version";
  };

  query = harnesses.wasixShell {
    name = "psql-query";
    shell = commands.bash;
    commands = psql;
    runtime.network = true;
    timeout = 900;
    host = {
      packages = nativePsql;
      setup = ''
        initdb -D db -U postgres --no-locale --encoding=UTF8 >/dev/null
        postgres -D db -k "$PWD" -h 127.0.0.1 -p 55432 >postgres.log 2>&1 &
        pid=$!

        for _ in $(seq 1 60); do
          if pg_isready -h 127.0.0.1 -p 55432 -U postgres >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        pg_isready -h 127.0.0.1 -p 55432 -U postgres
      '';
      teardown = ''
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      '';
    };
    script = ''

      psql -h 127.0.0.1 -p 55432 -U postgres -d postgres -Atc 'select 40 + 2'
    '';
  };

  tls = harnesses.wasixShell {
    name = "psql-tls";
    shell = commands.bash;
    commands = psql;
    runtime.network = true;
    timeout = 900;
    host = {
      packages = [pkgs.openssl] ++ nativePsql;
      setup = ''
        initdb -D db -U postgres --no-locale --encoding=UTF8 >/dev/null

        openssl req -x509 -newkey rsa:2048 \
          -keyout server.key -out server.crt -days 1 -nodes \
          -subj "/CN=127.0.0.1" >/dev/null 2>&1
        chmod 600 server.key
        cat >> db/postgresql.conf <<EOF
        ssl = on
        ssl_cert_file = '$(pwd)/server.crt'
        ssl_key_file = '$(pwd)/server.key'
        EOF

        postgres -D db -k "$PWD" -h 127.0.0.1 -p 55433 >postgres.log 2>&1 &
        pid=$!

        for _ in $(seq 1 60); do
          if pg_isready -h 127.0.0.1 -p 55433 -U postgres >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        pg_isready -h 127.0.0.1 -p 55433 -U postgres
      '';
      teardown = ''
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      '';
    };
    script = ''

      ssl_enabled=$(
        psql 'host=127.0.0.1 port=55433 user=postgres dbname=postgres sslmode=require' \
          -Atc 'select ssl from pg_stat_ssl where pid = pg_backend_pid()'
      )
      test "$ssl_enabled" = t
    '';
  };
}
