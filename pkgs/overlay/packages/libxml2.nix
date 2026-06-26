{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  configureFlags = ["--with-modules=no"];
} (prev.libxml2.override {
  enableHttp = false;
  pythonSupport = false;
  icuSupport = false;
})
