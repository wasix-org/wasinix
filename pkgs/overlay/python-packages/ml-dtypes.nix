# ml-dtypes for wasix (scikit-build-core). find_package(Python) and the
# CMakeLists' numpy probe both resolve to the build interpreter: pyport.h fatals
# on wasm32 (LONG_BIT 32), and numpy's 64-bit long mis-sizes npy_intp.
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
    postPatch = ''
      substituteInPlace CMakeLists.txt \
        --replace-fail 'import numpy; print(numpy.get_include())' "print('${py.pkgs.numpy.crossInclude}')"
    '';
  }
  pyprev.ml-dtypes
