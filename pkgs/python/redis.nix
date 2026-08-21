# redis 5.x needs pyjwt at runtime; 6.0 dropped it, so a rebase onto a 5.x src
# is missing it. buildPythonPackage folds `dependencies` into
# propagatedBuildInputs when it is called, so a later tweak names the latter.
{
  exposeExtendedPackage,
  packages,
  package,
  pkgs,
  lib,
}:
exposeExtendedPackage {
  propagatedBuildInputs =
    lib.optionals (lib.versionOlder package.version "6") [packages.sameProfile.pyjwt];
  redisTestPort = 0;
  passthru.wasinix.checks.captured.broken = "the Redis test hook cannot start its server inside the emulated check";
  passthru.wasixDeclaredCheckInputs = [
    packages.sameProfile.numpy
    packages.sameProfile.pytest-asyncio
    packages.sameProfile.pytestCheckHook
    packages.sameProfile.pybreaker
    packages.sameProfile.opentelemetry-api
    packages.sameProfile.opentelemetry-sdk
    pkgs.buildPackages.redisTestHook
  ];
  # Requires the fork multiprocessing context.
  disabledTestPaths = ["tests/test_multiprocessing.py"];
}
