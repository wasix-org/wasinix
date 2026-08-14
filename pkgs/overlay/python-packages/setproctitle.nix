{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The suite inspects and forks host processes; WASIX exposes neither view.
  passthru.wasix.installCheck = false;
}
pyprev.setproctitle
