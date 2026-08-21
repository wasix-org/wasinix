# No suite: the rust notify watcher traps the guest; wasix has no inotify for
# it to drive.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.checks.captured.install = false;
}
