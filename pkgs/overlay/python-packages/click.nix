{
  helpers,
  pyprev,
  ...
}:
helpers.libTweaks {
  # The editor tests resolve the build-host sed inside the guest. The atomic
  # mode tests need permission bits that Wasmer's filestat currently drops.
  disabledTests = [
    "test_fast_edit"
    "test_edit"
    "test_open_file_atomic_permissions_existing_file"
  ];
}
pyprev.click
