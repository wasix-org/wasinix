{
  exposeWasixPackage,
  extendPackage,
  package,
  profileOf,
}: let
  offProfile = profileOf package.stdenv.hostPlatform == "off";
in
  exposeWasixPackage (
    if offProfile
    then extendPackage package {cmakeFlags = ["-DUHDR_BUILD_TESTS=OFF"];}
    else package
  )
