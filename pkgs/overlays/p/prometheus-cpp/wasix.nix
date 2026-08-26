# The pkg-config files hydra's meson looks the libraries up by are generated
# only when cmake's UNIX is set, which it is not for wasm.
{
  exposeWasixExtendedPackage,
  profileSets,
}:
exposeWasixExtendedPackage {
  passthru.wasix.supportedProfiles = profileSets.withEh;
  cmakeFlags = ["-DGENERATE_PKGCONFIG=ON"];
}
