{
  final,
  helpers,
  prev,
  ...
}:
helpers.libTweaks {
  env = {
    AWS_LC_SYS_NO_JITTER_ENTROPY = "1";
    AWS_LC_SYS_CFLAGS = "-DOPENSSL_NO_TTY";
    RUSTFLAGS = "-Lnative=${final.buildPackages.wasix-sysroot}/sysroot-eh/lib/wasm32-wasi";
  };
  passthru.wasix.shipped = true;
  passthru.wasmer = {
    name = "attic-server";
    entrypoint = "atticd";
  };
}
prev.attic-server
