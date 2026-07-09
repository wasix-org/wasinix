# geos for wasix (shapely's C++ backend). Library-only: geosop uses fenv
# FE_* macros the wasm32 <fenv.h> doesn't define. C++ exceptions are load-
# bearing (throw everywhere), so no off profile.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  cmakeFlags = ["-DBUILD_GEOSOP=OFF"];
  # This geos is static-only: there is no shared libgeos_c.so to pull the C++
  # core transitively, so geos-config --clibs (which consumers like shapely
  # read for link libs) must list -lgeos itself. Upstream leaves it at
  # -lgeos_c (the dynamic convention).
  postInstall = ''
    substituteInPlace $out/bin/geos-config \
      --replace-fail 'echo -L''${libdir} -lgeos_c' 'echo -L''${libdir} -lgeos_c -lgeos'
  '';
  passthru.wasix.supportedProfiles = helpers.profiles.withEh;
}
prev.geos
