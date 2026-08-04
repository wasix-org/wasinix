# rapidfuzz for wasix (scikit-build-core). find_package(Python) resolves
# Development.Module to the build interpreter's 64-bit headers, so pyport.h fatals
# on wasm32 (LONG_BIT 32); point Python_INCLUDE_DIR at the wasix python.
{
  wasixPython,
  pyprev,
  helpers,
  ...
}: let
  py = wasixPython;
in
  helpers.libTweaks {
    cmakeFlags = ["-DPython_INCLUDE_DIR=${py.crossIncludeDir}"];
  }
  pyprev.rapidfuzz
