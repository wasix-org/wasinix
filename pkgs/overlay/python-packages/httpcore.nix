{
  pyprev,
  pyfinal,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasixDeclaredCheckInputs = [
    pyfinal.pytestCheckHook
    pyfinal.pytest-asyncio
    pyfinal.pytest-httpbin
    pyfinal.anyio
    pyfinal.h2
    pyfinal.hpack
    pyfinal.hyperframe
    pyfinal.socksio
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
pyprev.httpcore
