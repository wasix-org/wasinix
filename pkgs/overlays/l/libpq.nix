# libpq from nixpkgs' libpq. openssl (on by default) links our wasix build for
# TLS. curl (OAuth) and NLS stay off: a static libpq fails libcurl's
# curl_multi_init probe, and the wasi psql patch skips the locale setup NLS
# needs. tzdata is build-time data, so take the native one.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileOf,
  profileSets,
}: let
  lib = packages.sameProfile.lib;
  offProfile = profileOf package.stdenv.hostPlatform == "off";
in
  exposeWasixPackage (
    extendPackage (package.override {
      curlSupport = false;
      gssSupport = false;
      nlsSupport = false;
      tzdata = packages.sameProfile.buildPackages.tzdata;
    }) {
      passthru.wasix.supportedProfiles = profileSets.all;
      # The off sysroot lacks the signal-mask-preserving setjmp variants.
      postPatch = lib.optionalString offProfile ''
        substituteInPlace src/include/c.h \
          --replace-fail \
            '/* /port compatibility functions */' \
            '#if defined(__wasi__) && !defined(__wasm_exception_handling__)
        #define sigsetjmp(x,y) setjmp(x)
        #define siglongjmp longjmp
        #endif

        /* /port compatibility functions */'
      '';
      # wasm32-wasi matches no configure template; pick one explicitly.
      configureFlags = old: old ++ ["--with-template=linux"];
    }
  )
