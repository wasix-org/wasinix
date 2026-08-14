{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  # The upstream suite imports optional visualization and snapshot tooling.
  # The packaged library still receives its import check.
  passthru.wasix.installCheck = false;
}
pyprev.openai-agents
