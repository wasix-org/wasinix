{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.regex {
  disabledTests = ["test_main"];
}
