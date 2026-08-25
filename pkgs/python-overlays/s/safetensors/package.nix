{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  patches = [./patches/safetensors-wasi-read-exact-at.patch];
  passthru.wasixDeclaredCheckInputs = [packages.sameProfile.pytestCheckHook packages.sameProfile.numpy packages.sameProfile.fsspec];
  passthru.wasinix.update.notes = [
    {message = "safetensors: re-check the WASI read_exact_at patch on bump.";}
  ];
  # The WASIX registry does not ship the optional ML framework stacks.
  disabledTestPaths = [
    "tests/test_multithreaded.py"
    "tests/test_pread_backend.py"
    "tests/test_pt_comparison.py"
    "tests/test_pt_model.py"
    "tests/test_simple.py"
    "tests/test_tf_comparison.py"
  ];
  pytestFlags = [
    "--deselect=tests/test_handle.py::ReadmeTestCase::test_numpy_example"
    "--deselect=tests/test_handle.py::ReadmeTestCase::test_fsspec"
    "--deselect=tests/test_threadable.py::TestCase::test_serialize_file_releases_gil"
  ];
}
