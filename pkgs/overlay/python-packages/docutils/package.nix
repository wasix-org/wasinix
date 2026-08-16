{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./patches/portable-os-errors.patch];
}
pyprev.docutils
