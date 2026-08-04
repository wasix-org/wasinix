# h5py for wasix. setup_configure.py ctypes-loads libhdf5 on the BUILD host to
# read the version and feature flags, which the static wasm HDF5 cannot serve.
# That static HDF5 also needs zlib and libaec's sz/aec named on the link, which
# upstream gets through libhdf5.so.
{
  pyprev,
  final,
  wasixPython,
  lib,
  helpers,
  ...
}: let
  crossNumpyInc = wasixPython.pkgs.numpy.crossInclude;
in
  helpers.libTweaks {
    env.HDF5_VERSION = final.hdf5.version;
    env.H5PY_ROS3 = "0";
    env.H5PY_DIRECT_VFD = "0";
    buildInputs = [final.zlib final.libaec];
    # dtype.elsize reads 0 against the build python's numpy headers; NPY_2_0 gets
    # the version-independent PyDataType_ELSIZE accessor.
    postPatch = ''
      substituteInPlace setup_build.py \
        --replace-fail "numpy.get_include()" "'${crossNumpyInc}'" \
        --replace-fail "NPY_1_21_API_VERSION" "NPY_2_0_API_VERSION" \
        --replace-fail "'libraries'      : ['hdf5', 'hdf5_hl']," "'libraries'      : ['hdf5', 'hdf5_hl', 'z', 'sz', 'aec'],"
    '';
  }
  pyprev.h5py
