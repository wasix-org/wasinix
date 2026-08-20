# Both libcurl (linked by git/imagemagick via lib/libcurl.a, unaffected by
# the bin rename) and the curl CLI, shipped as curl.wasm. openssl, zlib,
# brotli and zstd auto-thread; the other *Support flags need libs we don't
# package yet (nghttp2, c-ares, libidn2, libpsl, ...).
{
  prev,
  helpers,
  preferredProfilePackages,
  ...
}:
helpers.wasmRename {wasmName = "curl";} (helpers.extendPackage (prev.curlMinimal.override {
    # Null the target shell package: cross curl would add the wasm bash-static
    # to buildInputs, and it can't build under EH (fork is hidden). wcurl gets
    # its shell from the bash webc dependency above instead.
    runtimeShellPackage = null;
    brotliSupport = true;
    c-aresSupport = false;
    gssSupport = false;
    http2Support = false;
    http3Support = false;
    websocketSupport = false;
    idnSupport = false;
    ldapSupport = false;
    opensslSupport = true;
    pslSupport = false;
    rtmpSupport = false;
    rustlsSupport = false;
    scpSupport = false;
    zlibSupport = true;
    zstdSupport = true;
  }) {
    passthru.wasinix.shipped = true;
    # wcurl is a target-side wrapper script; it execs /bin/bash, mounted from the
    # bash webc dependency at load (like git's SHELL_PATH=/bin/bash). curl-config
    # stays a build-host dev script in -dev (git's build runs it for link flags).
    passthru.wasmer.dependencies = [preferredProfilePackages.bash];
    # patchShebangs bakes the build bash into wcurl, which cross curl forbids in
    # $bin (outputChecks.disallowedReferences); repoint it at the mounted
    # /bin/bash. No -e guard on purpose: if a curl bump drops wcurl, sed errors
    # and fails the build, surfacing this fixup instead of silently no-op'ing.
    postFixup = ''
      sed -i '1s|^#!.*|#!/bin/bash|' "''${bin:-$out}/bin/wcurl"
    '';
  })
