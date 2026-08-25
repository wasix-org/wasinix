# stdenv.nix strips libjxl's hardcoded -fno-exceptions for the cross build.
{
  exposeWasixPackage,
  extendPackage,
  package,
  profileSets,
  dropInputsByName,
}:
exposeWasixPackage (
  extendPackage (package.override {enablePlugins = false;}) {
    # pkg_check_modules scopes PkgConfig::OpenEXR to lib/, so tools/ links without
    # -lOpenEXR and fails on undefined Imf_3_4 symbols.
    patches = [
      ./libjxl-openexr-global-imported-target.patch
    ];
    cmakeFlags = [
      "-DJPEGXL_ENABLE_TOOLS=ON"
      "-DJPEGXL_ENABLE_BENCHMARK=ON"
      "-DJPEGXL_ENABLE_EXAMPLES=ON"
      "-DJPEGXL_ENABLE_DEVTOOLS=ON"
      "-DJPEGXL_ENABLE_SJPEG=ON"
      "-DJPEGXL_ENABLE_OPENEXR=ON"
      "-DJPEGXL_ENABLE_TRANSCODE_JPEG=ON"
      "-DJPEGXL_ENABLE_MANPAGES=ON"
      "-DJPEGXL_ENABLE_DOXYGEN=ON"
      # No JVM targets wasm32-wasix, and gperftools rejects wasm32 in
      # basictypes.h ("Could not determine cache line length").
      "-DJPEGXL_ENABLE_JNI=OFF"
      "-DJPEGXL_ENABLE_TCMALLOC=OFF"
      "-DBUILD_TESTING=OFF"
    ];
    # The static cross layer moves buildInputs into propagatedBuildInputs.
    propagatedBuildInputs = dropInputsByName [
      "gperftools"
      "gdk-pixbuf"
      "gtest"
      "googletest"
    ];
    nativeBuildInputs = dropInputsByName [
      "gdk-pixbuf"
      "makeWrapper"
    ];
    passthru.wasix.supportedProfiles = profileSets.pic;
  }
)
