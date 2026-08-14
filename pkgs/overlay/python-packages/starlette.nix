{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace tests/test_testclient.py \
      --replace-fail 'import trio.lowlevel' '# Trio cases are disabled on WASIX.'
  '';
  passthru.wasixDeclaredCheckInputs = [
    pyfinal.pytestCheckHook
    pyfinal.pytest-asyncio
    pyfinal.anyio
    pyfinal.httpx
    pyfinal.httpx2
    pyfinal.itsdangerous
    pyfinal.jinja2
    pyfinal.python-multipart
    pyfinal.pyyaml
    pyfinal.sniffio
  ];
  # Trio dispatches WASIX to its kqueue backend. Register the suite's strict
  # marker without loading pytest-trio, then exclude the Trio cases.
  pytestFlags = ["--override-ini=markers=trio"];
  disabledTests = [
    "trio"
    "test_cors_allow_all_except_credentials"
    "test_file_response_range_multi_head"
    "test_staticfiles_304_with_last_modified_compare_last_req"
    "test_staticfiles_with_invalid_dir_permissions_returns_401"
  ];
}
pyprev.starlette
