{
  exposePackage,
  extendPackage,
  packageSet,
  profileSets,
  scope,
  wasmRename,
}: let
  common = extendPackage packageSet.libpq {
    pname = "psql";
    passthru.wasix.supportedProfiles = profileSets.withEh;
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
  };
  wasix = wasmRename {wasmName = "psql";} (extendPackage common {
    passthru.wasinix.shipped = true;
    passthru.wasmer = {
      env.PATH = "/bin";
      fs."/etc" = packageSet.writeTextDir "passwd" "postgres:x:0:0:PostgreSQL:/:/bin/sh\n";
    };
  });
in
  exposePackage (
    if scope == "wasix"
    then wasix
    else common
  )
