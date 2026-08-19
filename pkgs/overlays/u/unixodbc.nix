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
      postInstall = ''
        for la in "$out/lib/"*.la; do
          substituteInPlace "$la" \
            --replace-fail '/build/source/libltdl/./.libs/libdlopen.a' ""
        done
      '';
    }
    prev.unixodbc
  else prev.unixodbc
