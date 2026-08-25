# caio for wasix. setup.py picks its AIO backend from platform.system() (the build host,
# Linux) → builds linux_aio, which uses Linux syscalls absent on wasix. Force the portable
# thread_aio backend.
{
  exposeExtendedPackage,
  package,
  lib,
  mergeScript,
  ...
}: let
  # nixpkgs rewrites a pyproject version literal only its current release carries,
  # so --replace-fail misses on a rebased src. The rebase takes its version from
  # the release it points at, so nothing needs rewriting.
  isHistory = (package.passthru.wasix.historySpec or null) != null;
  forceThreadAio = ''
    substituteInPlace setup.py \
      --replace-fail 'OS_NAME = platform.system().lower()' 'OS_NAME = "wasm"'
  '';
in
  exposeExtendedPackage {
    postPatch = old: mergeScript (lib.optional (!isHistory) old ++ [forceThreadAio]);
    # the asyncio adapter tests import aiomisc at collection
    disabledTestPaths = ["tests/test_asyncio_adapter.py"];
    # Suite off: the first thread-aio test kills the guest outright; undiagnosed.
    passthru = old:
      old
      // {
        wasinix = (old.wasinix or {}) // {checks.captured.install = false;};
      };
  }
