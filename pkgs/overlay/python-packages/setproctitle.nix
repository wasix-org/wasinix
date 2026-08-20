{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The suite inspects and forks host processes; WASIX exposes neither view.
  passthru.wasinix.checks.captured.install = false;
}
pyprev.setproctitle
