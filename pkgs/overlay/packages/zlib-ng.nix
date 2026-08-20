{
  prev,
  helpers,
  ...
}:
helpers.extendPackage (prev.zlib-ng.override {gtest = null;}) {}
