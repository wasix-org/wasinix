# Both libcurl (linked by git/imagemagick via lib/libcurl.a, unaffected by
# the bin rename) and the curl CLI, shipped as curl.wasm. openssl, zlib,
# brotli and zstd auto-thread; the other *Support flags need libs we don't
# package yet (nghttp2, c-ares, libidn2, libpsl, ...).
{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "curl";} (helpers.libTweaks {} ((prev.curlMinimal.override {
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
  })
  .overrideAttrs (o: {
    # TODO: drop once wasix recv returns EAGAIN on an empty non-blocking
    # socketpair (or the patch is fixed for wasix). nixpkgs' backported
    # fix-wakeup-consumption.patch (curl 2a2104f3, #21549) adds a
    # Curl_wakeup_consume() read of the multi handle's wakeup socketpair in
    # multi_runsingle; on wasix that read never returns, hanging every network
    # transfer. The patch only fixes a busy-loop in event-based multi
    # processing, which the CLI does not use, so dropping it is safe.
    patches =
      builtins.filter
      (p: builtins.baseNameOf (toString p) != "fix-wakeup-consumption.patch")
      (o.patches or []);
  })))
