# The server runs single-user: the postmaster forks a backend per connection and
# WASIX fork() reports ENOTSUP, so it never reaches a listening state. The client
# tools reach a real server over TCP.
{
  commands,
  pkgs,
  entry,
  harnesses,
  packageForEntry,
  packages,
  ...
}: let
  postgres = builtins.attrValues entry.commands;
  native = pkgs."postgresql_${pkgs.lib.versions.major (packageForEntry packages entry).version}";
in {
  version = harnesses.wasixShell {
    name = "postgres-version";
    shell = commands.bash;
    commands = postgres;
    script = "postgres --version";
  };

  # plpgsql exercises the dlopen path: its handler is a shared module the
  # backend loads on the first call.
  single-user = harnesses.wasixShell {
    name = "postgres-single-user";
    shell = commands.bash;
    commands = postgres ++ [commands.coreutils commands.grep];
    timeout = 1800;
    script = ''
      initdb -D db -U postgres --no-locale --encoding=UTF8

      postgres --single -D db postgres >out.txt 2>&1 <<'SQL'
      create table t (id int primary key, s text);
      insert into t values (1, 'alpha'), (2, 'beta');
      select s from t where id = 2;
      create function double_it(n int) returns int language plpgsql as $$ begin return n * 2; end $$;
      select double_it(21);
      SQL

      cat out.txt
      grep -F 's = "beta"' out.txt
      grep -F 'double_it = "42"' out.txt

      pg_controldata -D db | grep -F 'Database cluster state:'
    '';
  };

  client = harnesses.wasixShell {
    name = "postgres-client";
    shell = commands.bash;
    commands = postgres;
    runtime.network = true;
    timeout = 1800;
    host = {
      packages = [native];
      setup = ''
        ${pkgs.lib.getExe' native "initdb"} -D native -U postgres --no-locale --encoding=UTF8 >/dev/null
        ${pkgs.lib.getExe' native "postgres"} -D native -c unix_socket_directories= \
          -h 127.0.0.1 -p 55434 >native.log 2>&1 &
        pid=$!

        for _ in $(seq 1 60); do
          if ${pkgs.lib.getExe' native "pg_isready"} -h 127.0.0.1 -p 55434 -U postgres >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        ${pkgs.lib.getExe' native "pg_isready"} -h 127.0.0.1 -p 55434 -U postgres
      '';
      teardown = ''
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      '';
    };
    script = ''

      psql -h 127.0.0.1 -p 55434 -U postgres -d postgres -q -c \
        "create table demo (id int primary key, s text);
         insert into demo values (1, 'alpha'), (2, 'beta')"
      createdb -h 127.0.0.1 -p 55434 -U postgres restored
      pg_dump -h 127.0.0.1 -p 55434 -U postgres -d postgres -t demo >demo.sql
      psql -h 127.0.0.1 -p 55434 -U postgres -d restored -q -f demo.sql

      test "$(psql -h 127.0.0.1 -p 55434 -U postgres -d restored -Atc \
        'select s from demo where id = 2')" = beta
    '';
  };

  postmaster = harnesses.wasixShell {
    name = "postgres-postmaster";
    shell = commands.bash;
    commands = postgres ++ [commands.coreutils];
    runtime.network = true;
    timeout = 1800;
    broken = "the postmaster forks its background workers, and WASIX fork() reports ENOTSUP";
    script = ''
      initdb -D db -U postgres --no-locale --encoding=UTF8 >/dev/null

      postgres -D db -c unix_socket_directories= \
        -h 127.0.0.1 -p 55435 >postgres.log 2>&1 &
      pid=$!
      trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT

      for _ in $(seq 1 30); do
        if pg_isready -h 127.0.0.1 -p 55435 -U postgres >/dev/null 2>&1; then
          exit 0
        fi
        sleep 1
      done

      cat postgres.log >&2
      exit 1
    '';
  };
}
