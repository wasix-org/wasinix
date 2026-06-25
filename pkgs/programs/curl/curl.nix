{
  toolchain,
  curlMinimal,
  openssl,
  zlib,
  ...
}:
(curlMinimal.override {
  brotliSupport = false;
  c-aresSupport = false;
  gssSupport = false;
  http2Support = false;
  http3Support = false;
  websocketSupport = false;
  idnSupport = false;
  ldapSupport = false;
  opensslSupport = true;
  inherit openssl;
  pslSupport = false;
  rtmpSupport = false;
  rustlsSupport = false;
  scpSupport = false;
  zlibSupport = true;
  inherit zlib;
  zstdSupport = false;
  stdenv = toolchain.stdenv;
}).overrideAttrs (old: {
  preConfigure =
    (old.preConfigure or "")
    + ''
    '';
  configureFlags =
    (old.configureFlags or [])
    ++ [
      "--host=${toolchain.host}"
    ];
  hardeningDisable = ["all"];
  doCheck = false;
  postInstall =
    (old.postInstall or "")
    + ''
      if [ -f "$bin/bin/curl" ]; then
        mv "$bin/bin/curl" "$bin/bin/curl.wasm"
      fi
    '';
})
