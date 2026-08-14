# No derived check: same sqlite-vec eval throw as langgraph; the suite also
# calls live inference endpoints.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.installCheck = false;
}
pyprev.smolagents
