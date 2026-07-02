# nixpkgs builds pynacl's HTML docs via sphinxHook, dragging a native sphinx
# and babel into the build closure; babel's test suite fails on missing tzdata
# in this nixpkgs pin and takes pynacl with it. The docs aren't needed, so
# drop the hook and its `doc` output. The wheel itself is cffi-over-libsodium,
# both already in the overlay.
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
in
  helpers.libTweaks (wheels.dropSphinxDocs []) pyprev.pynacl
