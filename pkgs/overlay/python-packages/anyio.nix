# Trio reaches its subprocess backend at import time, which requires waitid;
# WASIX does not export it. Keep AnyIO's asyncio and uvloop coverage while
# leaving that optional backend out of the guest check closure.
{
  pyfinal,
  pyprev,
  helpers,
  lib,
  ...
}:
helpers.libTweaks {
  pytestFlags = old: lib.filter (flag: flag != "-Wignore::trio.TrioDeprecationWarning") old;
  # CPython's experimental subinterpreter queues are not built for WASIX.
  # Loopback TLS blocks in Wasmer; see WASIX-TODO.md.
  disabledTestPaths = [
    "tests/streams/test_tls.py"
    "tests/test_subprocesses.py"
    "tests/test_to_process.py"
    "tests/test_to_interpreter.py"
  ];
  disabledTests = [
    "test_all_attributes"
    "test_is_char_device"
    "test_is_fifo"
    "test_is_mount"
    "test_is_socket"
    "test_chmod"
    "test_hardlink_to"
    "test_group"
    "test_owner"
    "test_copy"
    "test_copy_into"
    "test_cancel_wait_on_thread"
    "test_asyncio_run_sync_multiple"
  ];
  passthru = old:
    old
    // {
      wasinix = (old.wasinix or {}) // {checks.captured.timeout = 3600;};
      wasixDeclaredCheckInputs = [
        pyfinal.pytestCheckHook
        pyfinal.exceptiongroup
        pyfinal.hypothesis
        pyfinal.psutil
        pyfinal.pytest-mock
        pyfinal.pytest-timeout
        pyfinal.pytest-xdist
        pyfinal.trustme
        pyfinal.uvloop
      ];
    };
}
pyprev.anyio
