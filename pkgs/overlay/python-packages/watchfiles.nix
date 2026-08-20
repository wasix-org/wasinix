# No suite: the rust notify watcher traps the guest; wasix has no inotify for
# it to drive.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.install = false;
}
pyprev.watchfiles
