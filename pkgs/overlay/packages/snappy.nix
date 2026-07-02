# snappy's CMakeLists forces -fno-exceptions for Clang, and wasixcc rejects
# PIC + no-exceptions ("PIC without wasm exceptions is not a valid build
# configuration"), so snappy builds only on the non-PIC profiles. Nothing in
# the overlay depends on snappy (it is in the library matrix for coverage),
# so mark the PIC profiles unsupported rather than override the deliberate
# -fno-exceptions. Proper fix: relax the wasixcc rule (PIC shouldn't require
# wasm exceptions), then drop this gate.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.supportedProfiles = helpers.profiles.withoutPic;
}
prev.snappy
