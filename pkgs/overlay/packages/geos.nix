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
  passthru.wasix.supportedProfiles = helpers.profiles.withEh;
}
prev.geos
