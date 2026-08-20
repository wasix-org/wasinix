{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.broken = "the suite cannot import langgraph.checkpoint.sqlite";
}
pyprev.langgraph-prebuilt
