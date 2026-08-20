# psql is the postgres source tree built for the frontend only: the libpq base
# builds libpq (submake-libpq), then we build and install just src/bin/psql.
{
  final,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "psql";} (
  helpers.extendPackage final.libpq {
    passthru.wasix = {
      shipped = true;
    };
    passthru.wasmer = {
      # wasmer places the command at /bin, and PATH is what find_my_exec searches
      # to resolve the running program; without it psql cannot read a psqlrc.
      env.PATH = "/bin";
      # WASIX has no passwd database, so psql cannot default the user name from
      # geteuid() and every invocation needs an explicit -U. SYSCONFDIR is /etc,
      # so a psqlrc would land here too.
      fs."/etc" = final.writeTextDir "passwd" "postgres:x:0:0:PostgreSQL:/:/bin/sh\n";
    };
    pname = "psql";
    meta = {
      mainProgram = "psql";
      description = "PostgreSQL interactive terminal";
      longDescription = "A terminal-based front end for PostgreSQL that runs queries interactively or from scripts.";
    };
    postBuild = ''
      make -C src/bin/psql
    '';
    installPhase = _: ''
      runHook preInstall

      make -C src/bin/psql install

      runHook postInstall
    '';
    postInstall = ''
      rm -rf "$out/share"
    '';
  }
)
