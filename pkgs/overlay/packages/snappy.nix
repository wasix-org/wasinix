# snappy's CMakeLists forces -fno-exceptions for Clang, and wasixcc rejects PIC + no-exceptions
# ("PIC without wasm exceptions is not a valid build configuration"). So snappy builds at the
# non-PIC profiles (eh, exnrefEh, off) but not the PIC ones (ehpic, exnrefEhpic). Nothing in the
# overlay depends on snappy (it's only in the library matrix for coverage), so mark it unsupported
# on the PIC profiles rather than overriding snappy's deliberate -fno-exceptions.
#
# The deeper issue is the wasixcc rule itself — PIC shouldn't actually require wasm exceptions;
# relaxing that in the toolchain would be the proper fix, after which this gate can drop.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.supportedProfiles = helpers.profiles.withoutPic;
}
prev.snappy
