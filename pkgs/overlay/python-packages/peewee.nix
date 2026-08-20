# Suite off: _sqlite3 trips the wasm indirect-call trap mid-run, taking the
# guest down; WASIX-TODO.md tracks the extension-table issue.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.install = false;
}
pyprev.peewee
