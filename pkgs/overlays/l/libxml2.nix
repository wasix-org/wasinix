{
  exposeWasixPackage,
  extendPackage,
  package,
}:
exposeWasixPackage (
  extendPackage (package.override {
    enableHttp = false;
    pythonSupport = false;
    icuSupport = false;
  }) {
    # nixpkgs' own doCheck is already false on any cross build
    # (hostPlatform != buildPlatform); no override needed here.
    configureFlags = ["--with-modules=no"];
  }
)
