# garage: S3-compatible object store for self-hosted geo-distributed
# deployments. Nixpkgs owns the source, vendoring, and native
# packaging; this override carries only the WASIX compatibility changes.
{
  final,
  helpers,
  prev,
  toolchain,
  ...
}: let
  inherit (prev) lib;
  sysroot = toolchain.sysroot.variants.${helpers.profileOf prev.stdenv.hostPlatform}.sysroot;
in
  helpers.extendPackage prev.garage {
    patches = [
      ./patches/garage-manifest.patch
      ./patches/garage-code.patch
    ];

    cargoBuildNoDefaultFeatures = true;
    # lmdb needs heed's page_size, which has no wasi arm, and syslog a syslog(3)
    # the wasi libc bindings do not define. system-libs replaces bundled-libs so
    # the build links the sysroot's libsodium, zstd and sqlite.
    cargoBuildFeatures = old: lib.subtractLists ["bundled-libs" "lmdb" "syslog"] old ++ ["system-libs"];

    buildInputs = old: old ++ [final.libsodium final.sqlite final.zlib final.zstd];

    # sqlite's and libsodium's pkg-config Libs.private put -lz and -lpthread on
    # the link line, and rustc searches neither a buildInput's libdir nor the
    # sysroot (WASIX-TODO.md).
    env.RUSTFLAGS = "-L ${final.zlib}/lib -L ${sysroot}/lib/wasm32-wasi";

    # protobuf runs at build time; the package argument was resolved in the
    # target set.
    nativeBuildInputs = old:
      helpers.dropInputsByName ["protobuf"] old
      ++ [final.buildPackages.protobuf];

    passthru.wasinix.shipped = true;
  }
