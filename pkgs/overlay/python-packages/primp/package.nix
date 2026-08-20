# primp for wasix. maturin/pyo3 rquest fork (hyper/rustls on aws-lc-rs). Four
# wasi fixes:
# - postPatch: primp-reqwest gates its native TLS/hyper stack on `not(target_arch =
#   "wasm32")` (any wasm = fetch-API browser); refine to the target_os unknown/none
#   predicate its own if_wasm! macro uses, so wasi takes the native path.
# - postPatch: hickory's builder_tokio (resolv.conf, cfg unix/windows) is absent on
#   wasi; pin the ungated Google-DNS builder_with_config so the module compiles.
# - env: aws-lc-sys C (cc-rs CcBuilder, universal bindings, no bindgen) minus its two
#   wasi-incompatible sources: NO_JITTER_ENTROPY (needs -O0 + hi-res timer),
#   OPENSSL_NO_TTY (console.c's tty branch; the stub keeps evp.c's console symbols).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    for f in $(grep -rlE 'target_arch = "wasm32"' crates/primp-reqwest crates/primp); do
      substituteInPlace "$f" \
        --replace-quiet 'not(target_arch = "wasm32")' 'not(all(target_arch = "wasm32", any(target_os = "unknown", target_os = "none")))' \
        --replace-quiet 'cfg(target_arch = "wasm32")' 'cfg(all(target_arch = "wasm32", any(target_os = "unknown", target_os = "none")))'
    done
    substituteInPlace crates/primp-reqwest/src/dns/hickory.rs \
      --replace-fail 'TokioResolver::builder_tokio()' 'Ok::<_, NetError>(TokioResolver::builder_with_config(ResolverConfig::udp_and_tcp(&GOOGLE), TokioRuntimeProvider::default()))'
  '';
  env = {
    AWS_LC_SYS_NO_JITTER_ENTROPY = "1";
    AWS_LC_SYS_CFLAGS = "-DOPENSSL_NO_TTY";
  };
  maturinBuildFlags = ["--features" "pyo3/extension-module"];
  # No suite: the tests open real network connections, which block forever in
  # the no-route sandbox; signals cannot interrupt blocked reads
  # (WASIX-TODO.md).
  passthru.wasinix.checks.captured.install = false;
}
pyprev.primp
