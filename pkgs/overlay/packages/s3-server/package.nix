{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.shipped = true;
  meta.description = "Generic S3 server, built to WASIX";
}
prev.s3-server
