{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.extendPackage pyprev.urllib3 {
  postPatch = ''
    substituteInPlace test/test_util.py \
      --replace-fail 'chain(parse_url_host_map, non_round_tripping_parse_url_host_map)' 'list(chain(parse_url_host_map, non_round_tripping_parse_url_host_map))'
  '';
  passthru.wasixDeclaredCheckInputs =
    [
      pyfinal.httpx
      pyfinal.pyopenssl
      pyfinal.pytest-socket
      pyfinal.pytest-timeout
      pyfinal.pytestCheckHook
      pyfinal.quart
      pyfinal.quart-trio
      pyfinal.tornado
      pyfinal.trustme
      pyfinal.trio
    ]
    ++ lib.concatAttrValues pyprev.urllib3.passthru.optional-dependencies;
  passthru.wasinix.checks.captured = {
    shards = 8;
    tags = ["slow-tests"];
  };
}
