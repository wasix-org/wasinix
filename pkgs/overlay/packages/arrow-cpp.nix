# arrow-cpp for wasix, a static build for pyarrow. RapidJSON stays BUNDLED
# because arrow hash-verifies one specific pre-release commit, so nixpkgs' snapshot
# cannot be substituted; ARROW_RAPIDJSON_URL only makes that download hermetic.
{
  final,
  prev,
  helpers,
  ...
}: let
  lib = prev.lib;
  base = prev.arrow-cpp.override {
    enableShared = false;
    enableS3 = false;
    enableGcs = false;
    enableAzure = false;
    enableJemalloc = false;
    # cross tzdata doesn't build (tzcode needs getresuid), and only its runtime path is baked in
    tzdata = final.buildPackages.tzdata;
  };
in
  helpers.libTweaks {
    # orc/boost/grpc/gtest don't cross-build; the static stdenv mirrors the two lists.
    buildInputs = _: [final.zlib final.zstd final.lz4 final.snappy final.thrift final.openssl];
    propagatedBuildInputs = _: [final.zlib final.zstd final.lz4 final.snappy final.thrift final.openssl];
    doInstallCheck = false;
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
      "-DARROW_COMPUTE=ON"
      "-DARROW_FILESYSTEM=ON"
      "-DARROW_CSV=ON"
      "-DARROW_JSON=ON"
      "-DARROW_DATASET=ON"
      "-DARROW_ACERO=ON"
      "-DARROW_PARQUET=ON"
      "-DPARQUET_BUILD_EXECUTABLES=OFF"
      "-DPARQUET_REQUIRE_ENCRYPTION=ON"
      # thrift pulls in a headers-only boost need; native headers serve
      "-DBoost_INCLUDE_DIR=${final.buildPackages.boost.dev}/include"
      "-DARROW_WITH_SNAPPY=ON"
      "-DARROW_WITH_LZ4=ON"
      "-DARROW_WITH_ZLIB=ON"
      "-DARROW_WITH_ZSTD=ON"
      "-DARROW_WITH_BROTLI=OFF"
      "-DARROW_WITH_BZ2=OFF"
      "-DARROW_WITH_NLOHMANN_JSON=OFF"
      "-DARROW_WITH_UTF8PROC=OFF"
      "-DARROW_WITH_RE2=OFF"
      "-DARROW_USE_GLOG=OFF"
      "-DARROW_WITH_BACKTRACE=OFF"
      "-DRapidJSON_SOURCE=BUNDLED"
    ];
    # vendored xxhash goes NEON-via-SIMDe under __wasm_simd128__ (the wasixcc default),
    # expecting a SIMDe arm_neon.h we don't have. The header installs, so patching it also
    # covers consumers, which -DXXH_VECTOR=0 would not.
    postPatch = ''
      substituteInPlace src/arrow/vendored/xxhash/xxhash.h \
        --replace-fail '(defined(__wasm_simd128__) && XXH_HAS_INCLUDE(<arm_neon.h>))' "0"
    '';
    # nixpkgs' env points *_HOME at cross protobuf/snappy, which would then be built as
    # deps. *_TEST_DATA stays because nixpkgs' pyarrow eval reads it eagerly.
    env = old:
      {
        inherit (old) ARROW_TEST_DATA PARQUET_TEST_DATA;
        ARROW_RAPIDJSON_URL = final.buildPackages.fetchurl {
          url = "https://github.com/miloyip/rapidjson/archive/232389d4f1012dddec4ef84861face2d2ba85709.tar.gz";
          hash = "sha256-uSkKmm1ETI4Em9WJq4BODM8rBdxZhKGe1a510JAGSAY=";
        };
      }
      # rapidjson's CMakeLists asks for cmake 2.8, which cmake 4 refuses; arrow handles
      # that itself from 21. Only the env form reaches the ExternalProject's own cmake.
      // lib.optionalAttrs (lib.versionOlder base.version "21") {
        CMAKE_POLICY_VERSION_MINIMUM = "3.5";
      };
    # arrow's decimal/json paths throw, and io/hdfs_internal.cc includes dlfcn.h,
    # which only the PIC sysroots ship.
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
    passthru.wasix.updateNotes = [
      {message = "recheck ARROW_RAPIDJSON_URL against cpp/thirdparty/versions.txt (ARROW_RAPIDJSON_BUILD_VERSION + _SHA256_CHECKSUM); arrow hash-verifies it, so a bump that moves the pin fails the build";}
    ];
  }
  base
