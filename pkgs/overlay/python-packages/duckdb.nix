# duckdb for wasix. find_package(Python) resolves the build interpreter's 64-bit
# headers and pyport.h fatals, so Python_INCLUDE_DIR is pinned. nixpkgs symlinks
# overlay/packages/duckdb into external/duckdb, so its wasi patches ride along.
{
  wasixPython,
  pyprev,
  final,
  helpers,
  lib,
  ...
}: let
  py = wasixPython;
  # nixpkgs symlinks the C++ duckdb's src into external/duckdb, so a rebased
  # wheel compiles its own release against whichever tree that package carries.
  wheel =
    if (pyprev.duckdb.passthru.wasix.historySpec or null) == null
    then pyprev.duckdb
    else
      pyprev.duckdb.override {
        duckdb = final."duckdb_${lib.replaceStrings ["."] ["_"] pyprev.duckdb.version}";
      };
in
  helpers.libTweaks {
    # The build-host importlib.metadata cannot resolve a cross-layout version.
    dontCheckPythonMetadata = true;
    # The Python suite pulls optional native extension and service stacks. The
    # dedicated wheel check exercises the enabled DuckDB extensions instead.
    passthru.wasix.installCheck = false;
    cmakeFlags = [
      "-DPython_INCLUDE_DIR=${py.crossIncludeDir}"
      "-DBUILD_EXTENSIONS=core_functions;parquet;json;icu"
      # Autoloading reaches the network, and the platform binary is a wasm exe.
      "-DENABLE_EXTENSION_AUTOLOADING=OFF"
      "-DENABLE_EXTENSION_AUTOINSTALL=OFF"
      "-DDUCKDB_EXPLICIT_PLATFORM=wasm_threads"
      # duckdb_loader.cmake needs $<LINK_LIBRARY:WHOLE_ARCHIVE,...>, which cmake
      # defines per platform and not for "Wasi", failing generate outright.
      "-DCMAKE_CXX_LINK_LIBRARY_USING_WHOLE_ARCHIVE_SUPPORTED=TRUE"
      "-DCMAKE_CXX_LINK_LIBRARY_USING_WHOLE_ARCHIVE=LINKER:--whole-archive;<LINK_ITEM>;LINKER:--no-whole-archive"
    ];
  }
  wheel
