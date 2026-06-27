# Both the libcurl library (linked by git/imagemagick — they use lib/libcurl.a,
# unaffected by the bin rename) and the curl CLI, shipped as curl.wasm. openssl,
# zlib, brotli and zstd auto-thread; the remaining *Support flags need libs we
# don't package yet (nghttp2, c-ares, libidn2, libpsl, …).
{
  prev,
  helpers,
  ...
}:
helpers.wasmRename {wasmName = "curl";} (helpers.libTweaks {} (prev.curlMinimal.override {
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
