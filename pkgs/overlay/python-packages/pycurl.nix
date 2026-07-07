# pycurl for wasix. Cross setup.py would run the build-platform curl-config off
# PATH (native flags, shared libcurl.so, wrong file type for wasm-ld); point it
# at the wasix curl's script through a wrapper that answers --libs with
# --static-libs, so the extension links libcurl.a with its transitive deps
# (openssl/zlib/brotli/zstd, cf. gitMinimal). The wrapper (not a setup.py
# substitution) because nixpkgs' preConfigure already rewrote the option list.
{
  final,
  lib,
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  preConfigure = ''
    mkdir -p "$TMPDIR/curl-config-static"
    cat > "$TMPDIR/curl-config-static/curl-config" <<'EOF'
    #!/bin/sh
    [ "$1" = "--libs" ] && set -- --static-libs
    exec @curlConfig@ "$@"
    EOF
    sed -i 's/^    //; s|@curlConfig@|${lib.getDev final.curl}/bin/curl-config|' \
      "$TMPDIR/curl-config-static/curl-config"
    chmod +x "$TMPDIR/curl-config-static/curl-config"
    export PYCURL_CURL_CONFIG="$TMPDIR/curl-config-static/curl-config"
  '';
}
pyprev.pycurl
