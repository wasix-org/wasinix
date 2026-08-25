# gbenchmark picks a cycle counter per architecture and #errors on one it does
# not know. wasm has no cycle counter, but the file already carries a
# clock_gettime(CLOCK_MONOTONIC) fallback for architectures without one, which
# is what wasix provides.
{
  exposeWasixExtendedPackage,
  dropInputsByName,
}:
exposeWasixExtendedPackage {
  patches = [./cycleclock-wasm.patch];

  # gtest is built with exceptions, so its `__cxa_throw` finds nothing in the
  # exception-free profiles' libc++abi and the test executables fail to link.
  # A cross build cannot run them regardless.
  cmakeFlags = ["-DBENCHMARK_ENABLE_TESTING=OFF"];
  buildInputs = dropInputsByName ["gtest"];
  doCheck = false;
}
