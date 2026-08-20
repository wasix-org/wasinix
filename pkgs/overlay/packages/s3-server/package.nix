{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.shipped = true;
}
prev.s3-server
