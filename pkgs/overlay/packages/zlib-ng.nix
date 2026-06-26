{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {} (prev.zlib-ng.override {gtest = null;})
