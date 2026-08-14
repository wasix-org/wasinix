# No suite: the tests live inside the package, so pytest imports the source
# certifi, and they assert on cacert.pem, present only in the installed copy.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.installCheck = false;
}
pyprev.certifi
