{
  final,
  helpers,
  prev,
  ...
}:
helpers.libTweaks {
  env.RUSTFLAGS = "-Lnative=${final.buildPackages.wasix-sysroot}/sysroot-eh/lib/wasm32-wasi";
  patches = [./wasi-server.patch];
  postPatch = ''
    substituteInPlace server/Cargo.toml \
      --replace-fail 'aws-config = "1.8.1"' 'aws-config = { version = "1.8.1", default-features = false, features = ["rt-tokio", "credentials-process", "sso"] }' \
      --replace-fail 'aws-sdk-s3 = "1.135.0"' 'aws-sdk-s3 = { version = "1.135.0", default-features = false, features = ["sigv4a", "http-1x", "rustls", "rt-tokio"] }'
  '';
  postInstall = _: "";
  passthru.wasix.shipped = true;
  passthru.wasmer = {
    name = "attic-server";
    entrypoint = "atticd";
  };
}
prev.attic-server
