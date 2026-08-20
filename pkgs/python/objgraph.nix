{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.objgraph {
  # Graph rendering needs a native CLI; object counting does not.
  patches = _: [];
}
