{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  # test_suffix.sh fails on a wasmer bug, not on xz: the CLI fsync()s the
  # containing directory and wasmer answers EISDIR. Tracked in WASIX-TODO.md;
  # drop the XFAIL once fd_sync accepts a directory fd.
  checkFlagsArray = [''XFAIL_TESTS=test_suffix.sh''];
}
prev.xz
