# The pkg-config files hydra's meson looks the libraries up by are generated
# only when cmake's UNIX is set, which it is not for wasm.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  cmakeFlags = ["-DGENERATE_PKGCONFIG=ON"];
  # it throws, and civetweb underneath it needs an EH profile too
  passthru.wasix.supportedProfiles = helpers.profiles.withEh;
}
prev.prometheus-cpp
