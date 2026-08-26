# The two compiled daemons under wasmer. A native PostgreSQL server gives the
# evaluator a real Hydra schema to query without depending on the WASIX
# postmaster, which cannot fork its workers.
{
  commands,
  pkgs,
  harnesses,
  entry,
  packageForEntry,
  packages,
  ...
}: let
  hydraPackage = packageForEntry packages entry;
  hydra = hydraPackage.artifacts.pkg;
  wasix = builtins.attrValues entry.commands;
  # nix reads the user from LOGNAME when there is no passwd file to look up.
  forwardEnv = [
    "HOME"
    "TERM"
    "TZ"
    "LANG"
    "LC_ALL"
    "WASIX_TEST_ROOT"
    "LOGNAME"
    "USER"
    "HYDRA_DBI"
  ];
in {
  runtime-mounts = pkgs.runCommand "hydra-runtime-mounts" {} ''
    manifest=${hydra}/pkg/hydra/wasmer.toml
    ${pkgs.lib.concatMapStrings (path: ''
        grep -F '${builtins.unsafeDiscardStringContext (builtins.toJSON "${path}")} = "fs${path}"' "$manifest"
      '')
      hydraPackage.passthru.wasmer.selfMounts}
    touch "$out"
  '';

  # the argument parser is nix's, so a rejected flag means the module loaded and
  # main() ran
  arguments = harnesses.wasixShell {
    name = "hydra-arguments";
    shell = commands.bash;
    commands = wasix;
    script = ''
      for prog in hydra-evaluator hydra-queue-runner; do
        out=$($prog --help 2>&1 || true)
        case $out in
          *"unrecognised flag"*) ;;
          *) echo "$prog did not parse arguments: $out" >&2; exit 1 ;;
        esac
      done
    '';
  };

  database = harnesses.wasixShell {
    name = "hydra-database";
    shell = commands.bash;
    commands = wasix;
    runtime.network = true;
    inherit forwardEnv;
    timeout = 900;
    host = {
      packages = [pkgs.postgresql];
      setup = ''
        export LOGNAME=hydra USER=hydra
        initdb -D db -U hydra --no-locale --encoding=UTF8 >/dev/null
        postgres -D db -k "$PWD" -h 127.0.0.1 -p 55436 >postgres.log 2>&1 &
        pid=$!

        for _ in $(seq 1 60); do
          if pg_isready -h 127.0.0.1 -p 55436 -U hydra >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        pg_isready -h 127.0.0.1 -p 55436 -U hydra
        createdb -h 127.0.0.1 -p 55436 -U hydra hydra
        psql -h 127.0.0.1 -p 55436 -U hydra -d hydra -v ON_ERROR_STOP=1 \
          -f ${hydraPackage}/libexec/hydra/sql/hydra.sql >/dev/null

        schema_version=1
        for migration in ${hydraPackage}/libexec/hydra/sql/migrations/upgrade-*.sql; do
          version=''${migration##*-}
          version=''${version%.sql}
          if [ "$version" -gt "$schema_version" ]; then schema_version=$version; fi
        done
        psql -h 127.0.0.1 -p 55436 -U hydra -d hydra -q -c \
          "insert into SchemaVersion(version) values ($schema_version)"

        export HYDRA_DBI='dbi:Pg:dbname=hydra;host=127.0.0.1;port=55436;user=hydra'
        test "$(psql -h 127.0.0.1 -p 55436 -U hydra -d hydra -Atc \
          'select version from SchemaVersion')" = "$schema_version"
      '';
      teardown = ''
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
      '';
    };
    script = ''

      out=$(hydra-evaluator missing-project missing-jobset 2>&1 || true)
      case $out in
        *"the specified jobset does not exist or is disabled"*) ;;
        *) echo "expected a completed jobset query, got: $out" >&2; exit 1 ;;
      esac
    '';
  };
}
