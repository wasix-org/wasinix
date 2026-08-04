# nixpkgs builds pynacl's HTML docs via sphinxHook, dragging in babel, whose test
# suite fails on missing tzdata in this nixpkgs pin and takes pynacl down with it.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks (helpers.python.dropSphinxDocs []) pyprev.pynacl
