{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.cbor2 {
  disabledTests = ["test_datetime_date_out_of_range"];
}
