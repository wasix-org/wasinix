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
}
pyprev.caio
