# wrapt for wasix. _wrappers.c declares its getset getters and setters one
# argument short (no closure parameter). That is UB the native C ABI forgives
# but wasm's typed function tables trap on ("indirect call type mismatch") at
# the first proxy attribute access; ddtrace's import is the first consumer to
# hit it. Upstream bug, worth reporting.
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ../lib/wheels.nix {inherit lib;};
in
  wheels.onlyOnWasix pyprev.wrapt (
    helpers.libTweaks {
      patches = [./patches/c-slot-signatures.patch];
    }
    pyprev.wrapt
  )
