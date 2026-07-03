# snappy's CMakeLists forces -fno-exceptions, which wasixcc deduces into
# exceptions=off: whatever the profile, the artifact is built against the off
# sysroot (the abi check caught eh columns shipping off-ABI snappy). Declare
# what it actually is, an off-ABI library; nothing in the overlay consumes it
# (matrix coverage only). If a consumer at an EH profile ever needs it, patch
# the -fno-exceptions out of its CMakeLists instead.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix.supportedProfiles = ["off"];
}
prev.snappy
