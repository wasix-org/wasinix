{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.langgraph-prebuilt {
  passthru.wasinix.checks.captured.broken = "the suite cannot import langgraph.checkpoint.sqlite";
}
