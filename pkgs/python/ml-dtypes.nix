# ml-dtypes for wasix (scikit-build-core). find_package(Python) and the
# CMakeLists' numpy probe both resolve to the build interpreter: pyport.h fatals
# on wasm32 (LONG_BIT 32), and numpy's 64-bit long mis-sizes npy_intp.
{
  exposeExtendedPackage,
  packages,
}: let
  py = packages.sameProfile.python;
in
  exposeExtendedPackage {
    cmakeFlags = ["-DPython_INCLUDE_DIR=${py.crossIncludeDir}"];
    postPatch = ''
      substituteInPlace CMakeLists.txt \
        --replace-fail 'import numpy; print(numpy.get_include())' "print('${packages.sameProfile.numpy.crossInclude}')"
    '';
  }
