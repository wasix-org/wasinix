{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.s3-server {
  passthru.wasinix.shipped = true;
}
