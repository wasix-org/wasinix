# No derived check: same sqlite-vec eval throw as langgraph; the suite also
# calls live inference endpoints.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.smolagents {
  passthru.wasinix.checks.captured.install = false;
}
