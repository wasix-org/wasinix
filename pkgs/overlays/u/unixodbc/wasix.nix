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
    then
      extendPackage package {
        postInstall = ''
          for la in "$out/lib/"*.la; do
            substituteInPlace "$la" \
              --replace-fail '/build/source/libltdl/./.libs/libdlopen.a' ""
          done
        '';
      }
    else package
  )
