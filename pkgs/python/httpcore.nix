{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  passthru.wasixDeclaredCheckInputs = [
    packages.sameProfile.pytestCheckHook
    packages.sameProfile.pytest-asyncio
    packages.sameProfile.pytest-httpbin
    packages.sameProfile.anyio
    packages.sameProfile.h2
    packages.sameProfile.hpack
    packages.sameProfile.hyperframe
    packages.sameProfile.socksio
  ];
  postPatch = ''
    substituteInPlace tests/_async/test_connection_pool.py \
      --replace-fail 'import trio as concurrency' '# Trio cases are disabled on WASIX.'
  '';
  # Trio dispatches WASIX to its kqueue backend. Register the suite's strict
  # marker without loading pytest-trio, then exclude the Trio cases.
  pytestFlags = ["--override-ini=markers=trio"];
  disabledTests = ["trio"];
}
