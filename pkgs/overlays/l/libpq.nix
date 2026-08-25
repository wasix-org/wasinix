# libpq from nixpkgs' libpq. openssl (on by default) links our wasix build for
# TLS. curl (OAuth) and NLS stay off: a static libpq fails libcurl's
# curl_multi_init probe, and the wasi psql patch skips the locale setup NLS
# needs. tzdata is build-time data, so take the native one.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileSets,
}:
exposeWasixPackage (
  extendPackage (package.override {
    curlSupport = false;
    gssSupport = false;
    nlsSupport = false;
    tzdata = packages.sameProfile.buildPackages.tzdata;
  }) {
    # off sysroot's <setjmp.h> lacks the sigsetjmp postgres error handling needs.
    passthru.wasix.supportedProfiles = profileSets.withEh;
    # wasm32-wasi matches no configure template; pick one explicitly.
    configureFlags = old: old ++ ["--with-template=linux"];
  }
)
