# wasm-opt et al, running under wasmer rather than on the build host. Nothing in
# the wasix set consumes it, so CI covers the one profile it is verified on
# rather than rebuilding a large C++ tree per ABI.
{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  passthru.wasinix.ci.profiles = ["exnrefEhpic"];
}
