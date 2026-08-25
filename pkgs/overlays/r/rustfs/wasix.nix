# rustfs: MinIO-class distributed S3 object store.
# Nixpkgs owns the source, vendoring, and native packaging;
# this override carries only the WASIX compatibility changes.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  dropInputsByName,
}:
exposeWasixPackage (
  extendPackage (package.override {
    # cross tzdata doesn't build (tzcode needs getresuid), and TZDIR only names a
    # zoneinfo tree, which is platform-independent data
    tzdata = packages.sameProfile.buildPackages.tzdata;
  }) {
    patches = [
      ./patches/rustfs-manifest.patch
      ./patches/rustfs-code.patch
    ];
    # Nixpkgs builds the console with pnpm under the target stdenv, so it throws
    # ("unsupported os WasiP1") on evaluation. The core S3 server does not need
    # the embedded console assets, so postPatch copies in an empty tree.
    console = packages.sameProfile.buildPackages.emptyDirectory;

    # ftps/webdav are default protocol-server features pulling libunftp +
    # dav-server, both deeply unix. Keep the core S3 build.
    cargoBuildNoDefaultFeatures = true;
    # These package arguments were already resolved in the target set. Protobuf
    # runs at build time; the CA bundle is unused after disabling native tests.
    nativeBuildInputs = old:
      dropInputsByName ["protobuf" "nss-cacert"] old
      ++ [packages.sameProfile.buildPackages.protobuf];

    # RustFS's release profile uses thin LTO and one codegen unit. On its roughly
    # 100 MB wasm this whole-program link takes hours and risks OOM.
    env = old:
      (removeAttrs old ["SSL_CERT_FILE"])
      // {
        # Preserve nixpkgs' tokio_unstable setting and opt into the WASIX mio Waker.
        RUSTFLAGS = "--cfg tokio_unstable --cfg tokio_wasix_waker";
        CARGO_PROFILE_RELEASE_LTO = "false";
        CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
        CARGO_PROFILE_RELEASE_OPT_LEVEL = "1";
      };

    passthru.wasinix.shipped = true;

    # RustFS ships prereleases (1.0.0-rc.1), which semver expresses directly, so
    # publish the upstream version as it stands; the default coercion would read
    # the trailing number as a fourth component and refuse. `wasmer run
    # wasmer/rustfs` with no version cannot select a prerelease (WASIX-TODO.md).
    passthru.wasmer.version = v: v;
  }
)
