{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.timeout = 7200;
}
pyprev.sqlalchemy
