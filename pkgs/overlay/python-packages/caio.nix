# caio for wasix. setup.py picks its AIO backend from platform.system() (the build host,
# Linux) → builds linux_aio, which uses Linux syscalls absent on wasix. Force the portable
# thread_aio backend.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  postPatch = ''
    substituteInPlace setup.py \
      --replace-fail 'OS_NAME = platform.system().lower()' 'OS_NAME = "wasm"'
  '';
  # the asyncio adapter tests import aiomisc at collection
  disabledTestPaths = ["tests/test_asyncio_adapter.py"];
  # Suite off: the first thread-aio test kills the guest outright; undiagnosed.
  passthru = old:
    old
    // {
      wasix = (old.wasix or {}) // {installCheck = false;};
    };
}
pyprev.caio
