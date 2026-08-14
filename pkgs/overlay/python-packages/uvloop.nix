# uvloop for wasix. Links the overlay's patched libuv (nixpkgs' derivation
# already forces use_system_libuv). cpython declares PyOS_BeforeFork /
# PyOS_AfterFork_* only under HAVE_FORK, which the wasix python lacks; uvloop
# calls them unconditionally around uv_spawn. No-op them: uv_spawn returns
# ENOSYS on wasix (no fork), so the hooks would bracket nothing.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  env.NIX_CFLAGS_COMPILE = "-DPyOS_BeforeFork()= -DPyOS_AfterFork_Parent()= -DPyOS_AfterFork_Child()=";
  # both raise at import, aborting collection: test_process imports psutil,
  # test_tcp fails to load a helper module in the guest
  disabledTestPaths = ["tests/test_process.py" "tests/test_tcp.py"];
  # No suite: libuv itself aborts the guest mid-run (uv_close assertion),
  # taking the session down; the core loop does not run on wasix yet.
  passthru.wasix.installCheck = false;
}
pyprev.uvloop
