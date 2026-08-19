# nixpkgs pins gcc14Stdenv here for a hydra test failure it links to
# (NixOS/nixpkgs #476278); wasm has no gcc, so this builds with clang like
# everything else. configure link-tests PQexec against -lpq alone, which a
# static libpq cannot satisfy without the libraries its .pc file keeps private.
{
  prev,
  final,
  helpers,
  ...
}:
helpers.libTweaks {
  configureFlags = ["LIBS=-lpgcommon -lpgport -lssl -lcrypto -lm"];
  # the library throws
  passthru.wasix.supportedProfiles = helpers.profiles.withEh;
}
(prev.libpqxx.override {gcc14Stdenv = final.stdenv;})
