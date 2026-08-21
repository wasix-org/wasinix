# google/crc32c for wasix (google-crc32c's C backend). The gtest suite can't run
# cross; the cross stdenv shim strips crc32c's -fno-exceptions, see stdenv.nix.
{exposeExtendedPackage}:
exposeExtendedPackage {
  cmakeFlags = ["-DCRC32C_BUILD_TESTS=0"];
  doInstallCheck = false;
}
