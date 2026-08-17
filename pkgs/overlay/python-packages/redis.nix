# redis 5.x needs pyjwt at runtime; 6.0 dropped it, so a rebase onto a 5.x src
# is missing it. buildPythonPackage folds `dependencies` into
# propagatedBuildInputs when it is called, so a later tweak names the latter.
{
  pyprev,
  pyfinal,
  final,
  helpers,
  lib,
  ...
}:
helpers.libTweaks {
  propagatedBuildInputs =
    lib.optionals (lib.versionOlder pyprev.redis.version "6") [pyfinal.pyjwt];
  redisTestPort = 0;
  passthru.wasixDeclaredCheckInputs = [
    pyfinal.numpy
    pyfinal.pytest-asyncio
    pyfinal.pytestCheckHook
    pyfinal.pybreaker
    pyfinal.opentelemetry-api
    pyfinal.opentelemetry-sdk
    final.buildPackages.redisTestHook
  ];
  # Requires the fork multiprocessing context.
  disabledTestPaths = ["tests/test_multiprocessing.py"];
}
pyprev.redis
