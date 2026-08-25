{
  exposeWasixPackage,
  extendPackage,
  package,
}:
exposeWasixPackage (
  extendPackage (package.override {gtest = null;}) {}
)
