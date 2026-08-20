# No suite: the tests spawn the claude CLI and sys.executable, and an in-guest
# exec of a shebanged wasm re-enters the wasix-run stub (WASIX-TODO.md).
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasinix.checks.captured.install = false;
}
pyprev.claude-agent-sdk
