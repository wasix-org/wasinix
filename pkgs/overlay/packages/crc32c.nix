# google/crc32c for wasix (google-crc32c's C backend). Upstream forces
# -fno-exceptions, which wasixcc rejects in the pic profiles (PIC requires
# wasm exceptions); the portable fallback needs no arch-specific sources.
# ctest can't run cross, and gtest isn't needed without it.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  cmakeFlags = ["-DCRC32C_BUILD_TESTS=0"];
  postPatch = ''
    sed -i 's/-fno-exceptions//g' CMakeLists.txt
  '';
  doInstallCheck = false;
}
prev.crc32c
