# rustfs: MinIO-class distributed S3 object store, built to WASIX.
# Nixpkgs owns the source, vendoring, and native packaging;
# this override carries only the WASIX compatibility changes.
{
  final,
  helpers,
  prev,
  ...
}:
helpers.libTweaks {
  patches = [
    ./patches/rustfs-manifest.patch
    ./patches/rustfs-code.patch
  ];
  # Nixpkgs's private console derivation uses target stdenv and cannot evaluate
  # for WASI. The core S3 server does not require embedded console assets.
  postPatch = _: "";

  # ftps/webdav are default protocol-server features pulling libunftp +
  # dav-server, both deeply unix. Keep the core S3 build.
  cargoBuildNoDefaultFeatures = true;
  # These package arguments were already resolved in the target set. Protobuf
  # runs at build time; the CA bundle is unused after disabling native tests.
  nativeBuildInputs = old:
    helpers.dropInputsByName ["protobuf" "nss-cacert"] old
    ++ [final.buildPackages.protobuf];

  # RustFS's release profile uses thin LTO and one codegen unit. On its roughly
  # 100 MB wasm this whole-program link takes hours and risks OOM.
  env = old:
    (builtins.removeAttrs old ["SSL_CERT_FILE"])
    // {
      # Preserve nixpkgs' tokio_unstable setting and opt into the WASIX mio Waker.
      RUSTFLAGS = "--cfg tokio_unstable --cfg tokio_wasix_waker";
      CARGO_PROFILE_RELEASE_LTO = "false";
      CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
      CARGO_PROFILE_RELEASE_OPT_LEVEL = "1";
    };

  passthru.wasix.shipped = true;

  # The registry hides prereleases from `latest`, and a published WebC version
  # is numeric MAJOR.MINOR.PATCH. Fold 1.0.0-beta.N to 0.0.N until RustFS cuts a
  # stable release; the assertion makes that transition explicit.
  passthru.wasmer.version = v: let
    beta = builtins.match ".*-beta[.]([0-9]+)" v;
  in
    assert final.lib.assertMsg (beta != null) "rustfs: version ${v} is not <ver>-beta.N; update the semver fold"; "0.0.${builtins.head beta}";
}
prev.rustfs
