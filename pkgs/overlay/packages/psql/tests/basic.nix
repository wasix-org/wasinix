{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  psql = [wasmerPkgs.psql];
in {
  version = testLib.mkWasixRun {
    name = "psql-version";
    wasixPkgs = psql;
    script = "psql --version";
  };

  query = testLib.mkWasixRun {
    name = "psql-query";
    nativePkgs = [pkgs.postgresql_18];
    wasixPkgs = psql;
    wasmerArgs = ["--net"];
    timeout = 900;
    script = ''
      initdb -D db -U postgres --no-locale --encoding=UTF8 >/dev/null
      postgres -D db -k "$PWD" -h 127.0.0.1 -p 55432 >postgres.log 2>&1 &
      pid=$!
      trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT

      for _ in $(seq 1 60); do
        if pg_isready -h 127.0.0.1 -p 55432 -U postgres >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      pg_isready -h 127.0.0.1 -p 55432 -U postgres

      psql -h 127.0.0.1 -p 55432 -U postgres -d postgres -Atc 'select 40 + 2'
    '';
  };
}
