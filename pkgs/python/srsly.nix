{
  exposeExtendedPackage,
  packages,
  lib,
}:
exposeExtendedPackage {
  # setup.py prepends the running build interpreter's include directory,
  # making its 64-bit pyport.h win over the wasm32 Python headers.
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'include_dirs = [get_path("include"), ".", "srsly"]' 'include_dirs = [".", "srsly"]'
  '';
  # Run from the installed tree so the source package cannot shadow its
  # compiled msgpack and ujson submodules.
  preCheck = _: ''
    _site=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -m1 -- '-srsly-.*site-packages$')
    cd "$_site"
  '';
  # These tests target a compatibility module excluded from the wheel.
  disabledTestPaths =
    ["srsly/tests/cloudpickle"]
    ++ lib.optionals (lib.versionAtLeast packages.sameProfile.python.pythonVersion "3.14") ["srsly/tests/ujson/test_ujson.py"];
  disabledTests = [
    "test_duplicate_key_01"
    "test_duplicate_keys_02"
    "test_issue_135"
    "test_register_0_safe"
    "test_register_0_unsafe"
    "test_register_1_safe"
    "test_register_1_unsafe"
    "test_issue_223"
    "test_issue_245"
  ];
}
