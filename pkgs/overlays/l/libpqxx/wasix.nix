# nixpkgs pins gcc14Stdenv here for a hydra test failure it links to
# (NixOS/nixpkgs #476278); wasm has no gcc, so this builds with clang like
# everything else. configure link-tests PQexec against -lpq alone, which a
# static libpq cannot satisfy without the libraries its .pc file keeps private.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileSets,
}:
exposeWasixPackage (
  extendPackage (package.override {gcc14Stdenv = packages.sameProfile.stdenv;}) {
    passthru.wasix.supportedProfiles = profileSets.withEh;
    configureFlags = ["LIBS=-lpgcommon -lpgport -lssl -lcrypto -lm"];
    # The guest cannot connect to the native test server's Unix socket.
    preCheck = ''
      mkdir -p "$NIX_BUILD_TOP/run/postgresql"
      export PGHOST=127.0.0.1
      export postgresqlEnableTCP=1
    '';
    # the library throws
  }
)
