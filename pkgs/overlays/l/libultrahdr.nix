{
  exposePackage,
  extendPackage,
  package,
  profileOf,
}: let
  offProfile = profileOf package.stdenv.hostPlatform == "off";
in
  exposePackage (
    if offProfile
    then extendPackage package {cmakeFlags = ["-DUHDR_BUILD_TESTS=OFF"];}
    else package
  )
