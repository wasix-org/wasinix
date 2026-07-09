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
