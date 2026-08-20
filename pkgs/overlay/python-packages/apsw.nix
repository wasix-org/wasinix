# No suite: `python -m apsw.tests` requires a test extension compiled at test
# time, and the guest cannot exec a compiler.
{
  pyprev,
  helpers,
  ...
}:
helpers.extendPackage pyprev.apsw {
  passthru.wasinix.checks.captured.install = false;
}
