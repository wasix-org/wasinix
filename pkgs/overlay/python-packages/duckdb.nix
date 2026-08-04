# duckdb for wasix. find_package(Python) resolves the build interpreter's 64-bit
# headers and pyport.h fatals, so Python_INCLUDE_DIR is pinned. nixpkgs symlinks
# overlay/packages/duckdb into external/duckdb, so its wasi patches ride along.
{
  wasixPython,
  pyprev,
  helpers,
  ...
}: let
  py = wasixPython;
in
  helpers.libTweaks {
    # The build-host importlib.metadata cannot resolve a cross-layout version.
    dontCheckPythonMetadata = true;
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
  pyprev.duckdb
