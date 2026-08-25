# No suite: greenlet's stack switching traps the guest outright; nothing to
# deselect around.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.checks.captured.install = false;
}
