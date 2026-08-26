{
  exposeWasixExtendedPackage,
  profileSets,
}:
exposeWasixExtendedPackage {
  passthru.wasix.supportedProfiles = profileSets.pic;
  # HDF5's float type detection uses FE_INVALID, which wasix <fenv.h> lacks.
  patches = [
    ./patches/hdf5-wasi-fenv.patch
  ];
  # libaec's cmake config exports shared targets only, hiding the static szip lib.
  cmakeFlags = ["-DHDF5_USE_LIBAEC_STATIC=ON"];
}
