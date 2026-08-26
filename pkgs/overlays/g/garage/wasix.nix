# garage: S3-compatible object store for self-hosted geo-distributed
# deployments. Nixpkgs owns the source, vendoring, and native
# packaging; this override carries only the WASIX compatibility changes.
{
  exposeWasixExtendedPackage,
  packages,
  dropInputsByName,
  profileOf,
}: let
  inherit (packages.sameProfile) lib;
  sysroot = packages.native."wasix-sysroot".profiles.${profileOf packages.sameProfile.stdenv.hostPlatform}.sysroot;
in
  exposeWasixExtendedPackage {
    passthru.wasix.supportedProfiles = ["eh" "ehpic"];
    patches = [
      ./patches/garage-manifest.patch
      ./patches/garage-code.patch
    ];

    cargoBuildNoDefaultFeatures = true;
    # lmdb needs heed's page_size, which has no wasi arm, and syslog a syslog(3)
    # the wasi libc bindings do not define. system-libs replaces bundled-libs so
    # the build links the sysroot's libsodium, zstd and sqlite.
    cargoBuildFeatures = old: lib.subtractLists ["bundled-libs" "lmdb" "syslog"] old ++ ["system-libs"];

    buildInputs = old: old ++ [packages.sameProfile.libsodium packages.sameProfile.sqlite packages.sameProfile.zlib packages.sameProfile.zstd];

    # sqlite's and libsodium's pkg-config Libs.private put -lz and -lpthread on
    # the link line, and rustc searches neither a buildInput's libdir nor the
    # sysroot (WASIX-TODO.md).
    env.RUSTFLAGS = "-L ${packages.sameProfile.zlib}/lib -L ${sysroot}/lib/wasm32-wasi";

    # protobuf runs at build time; the package argument was resolved in the
    # target set.
    nativeBuildInputs = old:
      dropInputsByName ["protobuf"] old
      ++ [packages.sameProfile.buildPackages.protobuf];

    passthru.wasinix.shipped = true;
  }
