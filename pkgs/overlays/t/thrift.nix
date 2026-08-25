# C++ runtime lib only, for parquet (arrow ships pre-generated thrift
# sources). Boost is a header-only build dep; the native headers serve.
{
  exposeWasixPackage,
  extendPackage,
  package,
  packages,
  profileSets,
}:
exposeWasixPackage (
  extendPackage (package.override {
    static = true;
    boost = packages.sameProfile.buildPackages.boost;
    # unspliced withPackages would build a wasm env; only serves the compiler
    python3 = packages.sameProfile.buildPackages.python3;
    openssl = null;
    zlib = null;
    libevent = null;
  }) {
    # eh: wasm-opt corrupts the function-exists probes (WASIX-TODO.md)
    nativeBuildInputs = [packages.sameProfile.disableWasmOptInConfigureHook];
    cmakeFlags = [
      "-DBUILD_COMPILER=OFF"
      "-DWITH_AS3=OFF"
      "-DWITH_C_GLIB=OFF"
      "-DWITH_JAVA=OFF"
      "-DWITH_JAVASCRIPT=OFF"
      "-DWITH_NODEJS=OFF"
      "-DWITH_PYTHON=OFF"
      "-DWITH_OPENSSL=OFF"
      "-DWITH_ZLIB=OFF"
      "-DWITH_LIBEVENT=OFF"
    ];
    # throws (TException)
    passthru.wasix.supportedProfiles = profileSets.withEh;
  }
)
