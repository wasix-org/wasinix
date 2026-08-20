# No suite: greenlet's stack switching traps the guest outright; nothing to
# deselect around.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.install = false;
}
pyprev.eventlet
