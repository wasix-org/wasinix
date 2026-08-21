{
  exposePackage,
  extendPackage,
  package,
}:
exposePackage (
  extendPackage (package.override {gtest = null;}) {}
)
