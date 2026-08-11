# gbenchmark picks a cycle counter per architecture and #errors on one it does
# not know. wasm has no cycle counter, but the file already carries a
# clock_gettime(CLOCK_MONOTONIC) fallback for architectures without one, which
# is what wasix provides.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  patches = [./cycleclock-wasm.patch];
}
prev.gbenchmark
