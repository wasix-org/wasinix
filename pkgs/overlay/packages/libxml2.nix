{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # nixpkgs' own doCheck is already false on any cross build
  # (hostPlatform != buildPlatform); no override needed here.
  configureFlags = ["--with-modules=no"];
} (prev.libxml2.override {
  enableHttp = false;
  pythonSupport = false;
  icuSupport = false;
})
