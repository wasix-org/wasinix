{
  exposePackage,
  extendPackage,
  packageSet,
  profileSets,
}:
exposePackage (
  extendPackage packageSet.libpq {
    pname = "psql";
    passthru = old: let
      previous =
        if old == null
        then {}
        else old;
    in
      previous
      // {wasix = (previous.wasix or {}) // {supportedProfiles = profileSets.withEh;};};
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
