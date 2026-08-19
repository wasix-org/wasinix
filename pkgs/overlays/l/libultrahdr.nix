{
  prev,
  helpers,
  ...
}: let
  offProfile = (helpers.profileOf prev.stdenv.hostPlatform) == "off";
in
  if offProfile
  then
    helpers.libTweaks {
      cmakeFlags = ["-DUHDR_BUILD_TESTS=OFF"];
    }
    prev.libultrahdr
  else prev.libultrahdr
