# libzmq for wasix (pyzmq's C backend). Static only: pyzmq links libzmq.a into its
# extension module. Its socket/context classes throw, so no off profile.
{
  profileSets,
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  # wasm-opt false-negatives the cmake feature conftests (WASIX-TODO.md).
  nativeBuildInputs = [packages.sameProfile.disableWasmOptInConfigureHook];
  cmakeFlags = [
    "-DBUILD_SHARED=OFF"
    "-DBUILD_STATIC=ON"
    "-DBUILD_TESTS=OFF"
    "-DENABLE_DRAFTS=OFF"
  ];
  passthru.wasix.supportedProfiles = profileSets.withEh;
}
