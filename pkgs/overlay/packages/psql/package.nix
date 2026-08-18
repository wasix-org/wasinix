{
  final,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "psql";} (
  helpers.libTweaks {
    passthru.wasix = {
      shipped = true;
    };
    # WASIX has no passwd database, so without this psql cannot default the user
    # name from geteuid() and every invocation needs an explicit -U.
    passthru.wasmer.fs."/etc" = final.writeTextDir "passwd" "postgres:x:0:0:PostgreSQL:/:/bin/sh\n";
    pname = "psql";
    meta = {
      mainProgram = "psql";
      description = "PostgreSQL interactive terminal";
    };
    patches = [./patches/0001-skip-system-psqlrc-lookup-on-wasi.patch];
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
  final.libpq
)
