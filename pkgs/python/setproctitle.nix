{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.setproctitle {
  # The suite inspects and forks host processes; WASIX exposes neither view.
  passthru.wasinix.checks.captured.install = false;
}
