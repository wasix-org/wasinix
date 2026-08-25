# No derived check: same sqlite-vec eval throw as langgraph; the suite also
# calls live inference endpoints.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.checks.captured.install = false;
}
