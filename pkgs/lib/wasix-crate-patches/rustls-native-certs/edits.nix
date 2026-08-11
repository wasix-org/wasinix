# rustls-native-certs: 0.8.2/0.8.3 share a mechanical Unix-store rewrite;
# the other edited layouts use their floor patches.
{
  lib,
  rewriters,
  ...
}: {
  edited = ["=0.6.3" ">=0.8.1"];
  stock = ["<0.6.3" ">0.6.3, <0.8.1"];
  forVersion = {
    version,
    floorPatch,
  }: let
    mechanical = lib.versionAtLeast version "0.8.2" && lib.versionOlder version "0.8.4";
  in {
    patches = lib.optional (!mechanical) floorPatch;
    patchPhase = lib.optionalString mechanical "${rewriters.wasiNativeCerts}";
  };
}
