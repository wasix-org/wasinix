# libzmq for wasix (pyzmq's C backend). Static only: pyzmq links libzmq.a into its
# extension module. Its socket/context classes throw, so no off profile.
{
  final,
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # wasm-opt false-negatives the cmake feature conftests (WASIX-TODO.md).
  nativeBuildInputs = [final.disableWasmOptInConfigureHook];
  cmakeFlags = [
    "-DBUILD_SHARED=OFF"
    "-DBUILD_STATIC=ON"
    "-DBUILD_TESTS=OFF"
    "-DENABLE_DRAFTS=OFF"
  ];
  passthru.wasix.supportedProfiles = helpers.profiles.withEh;
}
prev.zeromq
