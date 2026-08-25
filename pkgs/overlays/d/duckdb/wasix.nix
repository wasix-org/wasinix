# duckdb for wasix. 1.5 moved the loadable-extension function out of the root
# CMakeLists.txt, so an older release takes the same edit cut against that file,
# and its wheel build still links the shell, which reaches httplib's if2ip.
# Patches go in the src, not patchPhase: the python duckdb wheel
# symlinks this src into its external/duckdb submodule (nixpkgs: ln -s ${duckdb.src}).
{
  profileSets,
  exposeWasixExtendedPackage,
  package,
  packages,
}: let
  inherit (packages.sameProfile) lib;
  patchedSrc = packages.sameProfile.buildPackages.applyPatches {
    name = "duckdb-source-wasi-${package.version}";
    inherit (package) src;
    patches =
      [
        ./patches/duckdb-wasi-no-file-lock.patch
        ./patches/duckdb-wasi-posix-semaphore.patch
        (
          if lib.versionOlder package.version "1.5"
          then ./patches/duckdb-wasi-static-loadable-ext-pre15.patch
          else ./patches/duckdb-wasi-static-loadable-ext.patch
        )
        ./patches/duckdb-icu-double-conversion-wasm.patch
      ]
      ++ lib.optional (lib.versionOlder package.version "1.5")
      ./patches/duckdb-wasi-no-if2ip-pre15.patch;
  };
in
  exposeWasixExtendedPackage {
    src = patchedSrc;
    cmakeFlags = [
      # Skips a probe that runs a just-built duckdb_platform_binary, here wasm.
      "-DDUCKDB_EXPLICIT_PLATFORM=wasm_threads"
      "-DDISABLE_EXTENSION_LOAD=ON"
      "-DDUCKDB_EXTENSION_CONFIGS=${./extensions.cmake}"
      # nixpkgs enables these; the demo extension uses inet_addr, undeclared in wasix-libc.
      "-DBUILD_UNITTESTS=OFF"
    ];
    # The non-PIC EH sysroots ship no <dlfcn.h>, which dl.hpp includes off Windows;
    # `off` compiles with -fno-exceptions, which libpg_query's try/throw rejects.
    passthru.wasix.supportedProfiles = profileSets.pic;
  }
