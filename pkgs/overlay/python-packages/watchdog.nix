# No suite: wasix has no inotify, so watchdog runs its polling fallback and
# the suite's event-delivery assertions against native observers fail.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.install = false;
}
pyprev.watchdog
