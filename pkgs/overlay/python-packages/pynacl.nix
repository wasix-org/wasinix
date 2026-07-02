# pynacl for wasix. nixpkgs builds pynacl's HTML docs via sphinxHook, which drags a
# native sphinx → babel into the build closure; babel's test suite is broken on
# missing tzdata in this nixpkgs pin, so the native babel fails and takes pynacl with
# it. The docs aren't needed for the wheel — drop the hook and its `doc` output.
# (The wheel itself is cffi-over-libsodium, both already in the overlay.)
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
in
  helpers.libTweaks (wheels.dropSphinxDocs []) pyprev.pynacl
