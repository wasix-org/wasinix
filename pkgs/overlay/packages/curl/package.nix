# Both libcurl (linked by git/imagemagick via lib/libcurl.a, unaffected by
# the bin rename) and the curl CLI, shipped as curl.wasm. openssl, zlib,
# brotli and zstd auto-thread; the other *Support flags need libs we don't
# package yet (nghttp2, c-ares, libidn2, libpsl, ...).
{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "curl";} (helpers.libTweaks {passthru.wasix.shipped = true;} (prev.curlMinimal.override {
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
}))
