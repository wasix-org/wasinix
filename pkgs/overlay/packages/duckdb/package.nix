# duckdb for wasix. Patches go in the src, not patchPhase: the python duckdb wheel
# symlinks this src into its external/duckdb submodule (nixpkgs: ln -s ${duckdb.src}).
{
  prev,
  helpers,
  ...
}: let
  patchedSrc = prev.buildPackages.applyPatches {
    name = "duckdb-source-wasi-${prev.duckdb.version}";
    src = prev.duckdb.src;
    patches = [
      ./patches/duckdb-wasi-no-file-lock.patch
      ./patches/duckdb-wasi-posix-semaphore.patch
      ./patches/duckdb-wasi-static-loadable-ext.patch
      ./patches/duckdb-icu-double-conversion-wasm.patch
    ];
  };
in
  helpers.libTweaks {
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
    passthru.wasix.supportedProfiles = helpers.profiles.pic;
  }
  prev.duckdb
