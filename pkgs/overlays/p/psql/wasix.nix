# psql is the postgres source tree built for the frontend only: the libpq base
# builds libpq (submake-libpq), then we build and install just src/bin/psql.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  wasmRename,
}:
exposeWasixPackage (
  wasmRename {wasmName = "psql";} (
    extendPackage package {
      passthru.wasinix.shipped = true;
      passthru.wasmer = {
        # wasmer places the command at /bin, and PATH is what find_my_exec searches
        # to resolve the running program; without it psql cannot read a psqlrc.
        env.PATH = "/bin";
        # WASIX has no passwd database, so psql cannot default the user name from
        # geteuid() and every invocation needs an explicit -U. SYSCONFDIR is /etc,
        # so a psqlrc would land here too.
        fs."/etc" = packages.sameProfile.writeTextDir "passwd" "postgres:x:0:0:PostgreSQL:/:/bin/sh\n";
      };
    }
  )
)
