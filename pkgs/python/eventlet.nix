# No suite: greenlet's stack switching traps the guest outright; nothing to
# deselect around.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.eventlet {
  passthru.wasinix.checks.captured.install = false;
}
