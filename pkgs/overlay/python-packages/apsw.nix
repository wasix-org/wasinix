# No suite: `python -m apsw.tests` requires a test extension compiled at test
# time, and the guest cannot exec a compiler.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.install = false;
}
pyprev.apsw
