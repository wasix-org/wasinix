# CGI runs its interpreter through fork, which wasix does not implement outside
# the off profile, and loading the SSL library through dlopen pulls <dlfcn.h>,
# which the non-PIC EH sysroots do not ship. Linking openssl replaces the
# dlopen; prometheus-cpp's metrics exposer serves no CGI.
{
  profileSets,
  exposeWasixExtendedPackage,
  packages,
}:
exposeWasixExtendedPackage {
  buildInputs = [packages.sameProfile.openssl];
  # CivetServer.cpp throws, so the C++ wrapper needs an EH profile.
  passthru.wasix.supportedProfiles = profileSets.withEh;
  cmakeFlags = [
    "-DCIVETWEB_DISABLE_CGI=ON"
    "-DCIVETWEB_ENABLE_SSL_DYNAMIC_LOADING=OFF"
    # LTO leaves bitcode in the archive instead of wasm objects, and the abi
    # check reads the objects' target features.
    "-DCIVETWEB_CXX_ENABLE_LTO=OFF"
  ];
}
