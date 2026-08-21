{
  exposeExtendedPackage,
  packages,
  package,
  lib,
}:
exposeExtendedPackage {
  postPatch = ''
    substituteInPlace test/test_util.py \
      --replace-fail 'chain(parse_url_host_map, non_round_tripping_parse_url_host_map)' 'list(chain(parse_url_host_map, non_round_tripping_parse_url_host_map))'
  '';
  passthru.wasixDeclaredCheckInputs =
    [
      packages.sameProfile.httpx
      packages.sameProfile.pyopenssl
      packages.sameProfile.pytest-socket
      packages.sameProfile.pytest-timeout
      packages.sameProfile.pytestCheckHook
      packages.sameProfile.quart
      packages.sameProfile.quart-trio
      packages.sameProfile.tornado
      packages.sameProfile.trustme
      packages.sameProfile.trio
    ]
    ++ lib.concatAttrValues package.passthru.optional-dependencies;
  passthru.wasinix.checks.captured = {
    shards = 8;
    tags = ["slow-tests"];
  };
}
