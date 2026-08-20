# psycopg2 for wasix. setup.py runs pg_config to locate libpq; the wasix one is a
# wasm binary the build host cannot execute, and a native one reports native paths,
# so its --libdir drops the native ELF libpq.so onto the link and wasm-ld rejects
# it. Splice in a native wrapper answering the path queries with wasix paths.
{
  final,
  lib,
  pyprev,
  helpers,
  ...
}: let
  nativePgConfig = lib.getExe' final.buildPackages.libpq.pg_config "pg_config";
  wasixDev = lib.getDev final.libpq;
  wasixLib = lib.getLib final.libpq;
  pgConfigWrapper = final.buildPackages.writeShellScriptBin "pg_config" ''
    case "$1" in
      --includedir) echo "${wasixDev}/include" ;;
      --includedir-server) echo "${wasixDev}/include/postgresql/server" ;;
      --libdir | --pkglibdir) echo "${wasixLib}/lib" ;;
      *) exec ${nativePgConfig} "$@" ;;
    esac
  '';
in
  helpers.libTweaks (
    helpers.python.dropSphinxDocs []
    // {
      # nixpkgs' own postPatch rewrites this same line to the wasm libpq.pg_config,
      # so replace it wholesale rather than concatenating onto it.
      postPatch = _: ''
        substituteInPlace setup.py \
          --replace-fail "self.pg_config_exe = self.build_ext.pg_config" \
                         'self.pg_config_exe = "${lib.getExe pgConfigWrapper}"'
      '';
    }
  )
  pyprev.psycopg2
