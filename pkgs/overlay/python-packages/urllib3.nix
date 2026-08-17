{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks {
  passthru.wasixDeclaredCheckInputs =
    [
      pyfinal.httpx
      pyfinal.pyopenssl
      pyfinal.pytest-socket
      pyfinal.pytest-timeout
      pyfinal.pytestCheckHook
      pyfinal.quart
      pyfinal.tornado
      pyfinal.trio
      pyfinal.trustme
    ]
    ++ lib.concatAttrValues pyprev.urllib3.passthru.optional-dependencies;
}
pyprev.urllib3
