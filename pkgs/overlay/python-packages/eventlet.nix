# No suite: greenlet's stack switching traps the guest outright; nothing to
# deselect around.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.installCheck = false;
}
pyprev.eventlet
