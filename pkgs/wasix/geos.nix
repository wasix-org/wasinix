# geos for wasix (shapely's C++ backend). Library-only, no suite: geosop and
# tests/unit use fenv FE_* macros the wasm32 <fenv.h> does not define
# (WASIX-TODO.md). C++ exceptions are load-bearing, so no off profile.
{
  exposeExtendedPackage,
  profileSets,
}:
exposeExtendedPackage {
  doCheck = false;
  cmakeFlags = ["-DBUILD_GEOSOP=OFF"];
  # This geos is static-only: there is no shared libgeos_c.so to pull the C++
  # core transitively, so geos-config --clibs (which consumers like shapely
  # read for link libs) must list -lgeos itself. Upstream leaves it at
  # -lgeos_c (the dynamic convention).
  postInstall = ''
    substituteInPlace $out/bin/geos-config \
      --replace-fail 'echo -L''${libdir} -lgeos_c' 'echo -L''${libdir} -lgeos_c -lgeos'
  '';
  passthru.wasix.supportedProfiles = profileSets.withEh;
}
