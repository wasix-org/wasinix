# nixpkgs builds pynacl's HTML docs via sphinxHook, dragging a native sphinx
# and babel into the build closure; babel's test suite fails on missing tzdata
# in this nixpkgs pin and takes pynacl with it. The docs aren't needed, so
# drop the hook and its `doc` output. The wheel itself is cffi-over-libsodium,
# both already in the overlay.
{
  pyfinal,
  pyprev,
  lib,
  helpers,
  ...
}: let
in
  helpers.libTweaks (helpers.python.dropSphinxDocs []
    // {
      # Replaces the stashed check inputs: the inherited hypothesis is the
      # build-platform one, whose Rust _native the guest cannot import.
      passthru = old:
        old
        // {
          wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.hypothesis];
        };
      # -ra: pynacl's own quiet flags hide which tests fail
      pytestFlags = ["-ra"];
      # libsodium's argon2/scrypt hashes come out wrong on wasm32
      # (WASIX-TODO.md); deselected so the rest of the suite reports
      disabledTestPaths = ["tests/test_pwhash.py"];
    })
  pyprev.pynacl
