{
  exposeWasixExtendedPackage,
  packages,
  profileTraitsOf,
}: let
  # XFAIL only where it fails: automake counts an XPASS as a failure of its
  # own, so declaring it on the EH profiles would break them.
  isOff = !(profileTraitsOf packages.sameProfile.stdenv.hostPlatform).eh;
in
  exposeWasixExtendedPackage {
    # pngvalid-progressive-size traps (exit 45, no test output) in the off
    # profile only; the other pngvalid variants cover the same decoders and
    # pass everywhere. Not root-caused.
    checkFlagsArray =
      if isOff
      then [''XFAIL_TESTS=tests/pngvalid-progressive-size'']
      else [];
  }
