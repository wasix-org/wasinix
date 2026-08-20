# pycurl for wasix. Cross setup.py would run the build-platform curl-config off
# PATH (native flags, shared libcurl.so, wrong file type for wasm-ld); point it
# at the wasix curl's script through a wrapper that answers --libs with
# --static-libs, so the extension links libcurl.a with its transitive deps
# (openssl/zlib/brotli/zstd, cf. git). The wrapper (not a setup.py
# substitution) because nixpkgs' preConfigure already rewrote the option list.
{
  final,
  lib,
  pyfinal,
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.pycurl {
  preConfigure = ''
    mkdir -p "$TMPDIR/curl-config-static"
    cat > "$TMPDIR/curl-config-static/curl-config" <<'EOF'
    #!/bin/sh
    [ "$1" = "--libs" ] && set -- --static-libs
    exec @curlConfig@ "$@"
    EOF
    sed -i 's/^    //; s|@curlConfig@|${lib.getExe' (lib.getDev final.curl) "curl-config"}|' \
      "$TMPDIR/curl-config-static/curl-config"
    chmod +x "$TMPDIR/curl-config-static/curl-config"
    export PYCURL_CURL_CONFIG="$TMPDIR/curl-config-static/curl-config"
  '';
  # cadata/certinfo: TLS over loopback fails then blocks under wasmer
  # (WASIX-TODO.md). setup_test execs fake-curl shell scripts; the guest has
  # no shell to run their shebangs. callback_signals needs SIGINT to interrupt
  # a blocked write callback (WASIX-TODO.md).
  disabledTestPaths = [
    "tests/cadata_test.py"
    "tests/certinfo_test.py"
    "tests/setup_test.py"
    "tests/test_callback_signals.py"
  ];
  # the fixture server's first raw-socket exchange times out under emulation;
  # later parametrizations pass
  pytestFlags = ["--deselect=tests/test_connect_only_send_recv.py::test_connect_only_send_recv_byteslike[bytes]"];
  # Replaces the stashed check inputs: the inherited numpy is the
  # build-platform one; flask and bottle serve the loopback fixtures.
  passthru = old:
    old
    // {
      wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.flaky pyfinal.flask pyfinal.bottle pyfinal.numpy];
    };
}
