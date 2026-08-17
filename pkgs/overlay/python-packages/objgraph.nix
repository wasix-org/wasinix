{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # Graph rendering needs a native CLI; object counting does not.
  patches = _: [];
}
pyprev.objgraph
