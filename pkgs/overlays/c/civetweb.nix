# CGI runs its interpreter through fork, which wasix does not implement outside
# the off profile, and loading the SSL library through dlopen pulls <dlfcn.h>,
# which the non-PIC EH sysroots do not ship. Linking openssl replaces the
# dlopen; prometheus-cpp's metrics exposer serves no CGI.
{
  exposeWasixExtendedPackage,
  packages,
  profileSets,
}:
exposeWasixExtendedPackage {
  passthru.wasix.supportedProfiles = profileSets.withEh;
  buildInputs = [packages.sameProfile.openssl];
  cmakeFlags = [
    "-DCIVETWEB_DISABLE_CGI=ON"
    "-DCIVETWEB_ENABLE_SSL_DYNAMIC_LOADING=OFF"
    # LTO leaves bitcode in the archive instead of wasm objects, and the abi
    # check reads the objects' target features.
    "-DCIVETWEB_CXX_ENABLE_LTO=OFF"
  ];
}
