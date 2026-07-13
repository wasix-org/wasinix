# arrow-cpp for wasix: a minimal static build carrying exactly what pyarrow
# needs (compute/csv/json/filesystem/ipc/parquet + zlib/zstd/lz4/snappy
# codecs). All network/storage backends, allocators (jemalloc/mimalloc don't
# target wasm), orc/dataset/acero and the test/utility executables are off.
# RapidJSON comes BUNDLED (header-only vendor drop) because nixpkgs'
# rapidjson derivation builds wasm gtest binaries.
{
  final,
  prev,
  helpers,
  ...
}: let
  base = prev.arrow-cpp.override {
    enableShared = false;
    enableS3 = false;
    enableGcs = false;
    enableAzure = false;
    enableJemalloc = false;
    # cross tzdata doesn't build (tzcode needs getresuid); the data is
    # platform-independent and only baked in as a runtime zoneinfo path.
    tzdata = final.buildPackages.tzdata;
  };
in
  helpers.libTweaks {
    # replace nixpkgs' full input set (orc/boost/grpc/gtest/... don't
    # cross-build); the static stdenv mirrors buildInputs into
    # propagatedBuildInputs, so replace both.
    buildInputs = _: [final.zlib final.zstd final.lz4 final.snappy final.thrift];
    propagatedBuildInputs = _: [final.zlib final.zstd final.lz4 final.snappy final.thrift];
    doInstallCheck = false;
    # appended after nixpkgs' flags; for duplicated -D options the last wins
    cmakeFlags = [
      # SetupCxxFlags fatals on unknown processors; wasm32 has no arch flags
      "-DARROW_CPU_FLAG=wasm32"
      "-DARROW_SIMD_LEVEL=NONE"
      "-DARROW_RUNTIME_SIMD_LEVEL=NONE"
      "-DARROW_BUILD_INTEGRATION=OFF"
      "-DARROW_BUILD_UTILITIES=OFF"
      "-DARROW_ORC=OFF"
      "-DARROW_SUBSTRAIT=OFF"
      "-DARROW_MIMALLOC=OFF"
      "-DARROW_HDFS=OFF"
      "-DARROW_DATASET=OFF"
      "-DARROW_ACERO=OFF"
      "-DARROW_PARQUET=ON"
      "-DPARQUET_BUILD_EXECUTABLES=OFF"
      "-DPARQUET_REQUIRE_ENCRYPTION=OFF"
      # thrift pulls in a headers-only boost need; native headers serve
      "-DBoost_INCLUDE_DIR=${final.buildPackages.boost.dev}/include"
      "-DARROW_WITH_SNAPPY=ON"
      "-DARROW_WITH_BROTLI=OFF"
      "-DARROW_WITH_BZ2=OFF"
      "-DARROW_WITH_NLOHMANN_JSON=OFF"
      "-DARROW_WITH_UTF8PROC=OFF"
      "-DARROW_WITH_RE2=OFF"
      "-DARROW_USE_GLOG=OFF"
      "-DARROW_WITH_BACKTRACE=OFF"
      "-DRapidJSON_SOURCE=BUNDLED"
    ];
    # vendored xxhash goes NEON-via-SIMDe whenever __wasm_simd128__ is set
    # (wasixcc default), expecting a SIMDe arm_neon.h shim we don't have (it
    # picks up clang's ARM-only one). Neutralize the condition, used twice:
    # the header include and the XXH_VECTOR auto-detect. The header installs,
    # so consumers (pyarrow) compile it too; patching beats -DXXH_VECTOR=0.
    postPatch = ''
      substituteInPlace src/arrow/vendored/xxhash/xxhash.h \
        --replace-fail '(defined(__wasm_simd128__) && XXH_HAS_INCLUDE(<arm_neon.h>))' "0"
    '';
    # replace nixpkgs' env: it points *_HOME at cross protobuf/snappy (which
    # would be built as deps). The *_TEST_DATA paths stay: nixpkgs' pyarrow
    # eval reads them eagerly (they're plain fetched sources, never used here).
    env = old: {
      inherit (old) ARROW_TEST_DATA PARQUET_TEST_DATA;
      ARROW_RAPIDJSON_URL = final.buildPackages.fetchurl {
        url = "https://github.com/miloyip/rapidjson/archive/232389d4f1012dddec4ef84861face2d2ba85709.tar.gz";
        hash = "sha256-uSkKmm1ETI4Em9WJq4BODM8rBdxZhKGe1a510JAGSAY=";
      };
    };
    # arrow throws (Status is the norm, but decimal/json paths do throw), and
    # io/hdfs_internal.cc includes dlfcn.h, which only the PIC sysroots ship.
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
  }
  base
